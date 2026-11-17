//
//  ClerkRuntime.swift
//  ClerkKit
//

import Foundation

/// Everything Clerk builds for one installed configuration: the dependency container,
/// the managers that run beside it, their observers, and every task they start.
@MainActor
final class ClerkRuntime {
  weak let clerk: Clerk?
  let state: ClerkRuntimeState
  var dependencies: any Dependencies
  var internalStateChanges = ClerkInternalStateChangeEmitter()

  private(set) lazy var startupClientRefreshTakeover = StartupClientRefreshTakeover(runtime: self)

  private let tasks = TaskCoordinator()
  private var cacheManager: CacheManager?
  private var sessionPollingManager: SessionPollingManager?
  private var lifecycleManager: LifecycleManager?
  private var watchConnectivityCoordinator: WatchConnectivityCoordinator?
  private var sharedIdentityNotifier: SharedIdentityNotifier?

  private var environmentRefreshTask: Task<Clerk.Environment, Error>?
  private var environmentRefreshTaskID: UUID?
  private struct ClientRefresh {
    let id: UUID
    var generation: ClientResponseGeneration
    let task: Task<Client?, Error>
    var isCompleted = false
  }

  @MainActor
  private final class ClientRefreshWaiter {
    private var result: Result<Client?, Error>?
    private var continuation: CheckedContinuation<Client?, Error>?

    func value() async throws -> Client? {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { continuation in
        if let result {
          continuation.resume(with: result)
        } else {
          self.continuation = continuation
        }
      }
    }

    func resolve(_ result: Result<Client?, Error>) {
      guard case nil = self.result else { return }
      self.result = result
      continuation?.resume(with: result)
      continuation = nil
    }
  }

  private var lifecycleClientRefresh: ClientRefresh?
  private var startupClientRefreshTask: ClientRefresh?
  private var invalidAuthRefreshTask: Task<Void, Never>?
  private var foregroundNeedsClientRefresh = false

  private static let startupRefreshRetryPolicy = RetryPolicy(
    maxAttempts: 3,
    initialDelay: .milliseconds(500),
    maximumDelay: .seconds(5)
  )

  init(clerk: Clerk, state: ClerkRuntimeState, dependencies: any Dependencies) {
    self.clerk = clerk
    self.state = state
    self.dependencies = dependencies
  }

  var isCurrent: Bool {
    state.isCurrent
  }

  func start() {
    stop()
    guard let clerk else { return }

    clerk.identityController.prepareForConfiguration()
    clerk.reconcileBiometricCredentialsForCurrentInstallation()

    let sessionPollingManager = SessionPollingManager(
      sessionProvider: clerk,
      authEventsProvider: { [weak clerk] in
        clerk?.auth.events ?? AsyncStream { $0.finish() }
      },
      tasks: tasks
    )
    let lifecycleManager = LifecycleManager(handler: self)
    self.sessionPollingManager = sessionPollingManager
    self.lifecycleManager = lifecycleManager
    sessionPollingManager.startPolling()
    lifecycleManager.startObserving()

    clerk.identityController.hydrate()

    let cacheManager = CacheManager(
      coordinator: clerk,
      keychain: dependencies.appLocalKeychain,
      writes: dependencies.cacheWrites
    )
    self.cacheManager = cacheManager
    internalStateChanges.addObserver(cacheManager)
    cacheManager.loadCachedData()

    if dependencies.configurationManager.options.watchConnectivityEnabled {
      let coordinator = WatchConnectivityCoordinator()
      watchConnectivityCoordinator = coordinator
      internalStateChanges.addObserver(coordinator)
    }
    installSharedIdentityNotifier(clerk: clerk)

    clerk.startAutomaticPresenter()

    scheduleStartupEnvironmentRefresh()
    startStartupClientRefreshIfNeeded()
  }

  func stop() {
    cancelRefreshes()
    stopManagers()
    tasks.cancelAll()
  }

  func shutdown() async {
    state.retire()
    cancelRefreshes()
    stopManagers()
    await tasks.cancelAllAndWait()
    await dependencies.cacheWrites.waitForPendingWrites()

    let telemetry = dependencies.telemetryCollector
    Task(priority: .utility) {
      await telemetry.flush()
    }
  }

  @discardableResult
  func scheduleTask(
    priority: TaskPriority = .userInitiated,
    operation: @escaping @Sendable () async -> Void
  ) -> Task<Void, Never> {
    tasks.task(priority: priority, operation: operation)
  }

  private func installSharedIdentityNotifier(clerk: Clerk) {
    let keychainConfig = dependencies.configurationManager.options.keychainConfig
    guard dependencies.identityIsInAccessGroup, let accessGroup = keychainConfig.normalizedAccessGroup else { return }
    let notifier = SharedIdentityNotifier(name: "\(accessGroup).clerk.\(keychainConfig.service)", clerk: clerk)
    sharedIdentityNotifier = notifier
    internalStateChanges.addObserver(notifier)
  }

  private func cancelRefreshes() {
    foregroundNeedsClientRefresh = false
    cancelStartupClientRefresh()
    lifecycleClientRefresh?.task.cancel()
    lifecycleClientRefresh = nil
    invalidAuthRefreshTask?.cancel()
    invalidAuthRefreshTask = nil
    environmentRefreshTask?.cancel()
    environmentRefreshTask = nil
    environmentRefreshTaskID = nil
  }

  private func stopManagers() {
    clerk?.stopAutomaticPresenter()
    watchConnectivityCoordinator?.stopAcceptingIdentityUpdates()
    watchConnectivityCoordinator = nil
    sharedIdentityNotifier?.stop()
    sharedIdentityNotifier = nil
    cacheManager?.shutdown()
    cacheManager = nil
    sessionPollingManager?.stopPolling()
    sessionPollingManager = nil
    lifecycleManager?.stopObserving()
    lifecycleManager = nil
    internalStateChanges.removeAllObservers()
  }
}

extension ClerkRuntime {
  func refreshEnvironment() async throws -> Clerk.Environment {
    if let environmentRefreshTask {
      return try await environmentRefreshTask.value
    }

    guard let clerk else { throw CancellationError() }
    let runtime = clerk.runtimeScope
    let taskID = UUID()
    let task = Task { @MainActor [weak self] in
      defer {
        if let self, self.environmentRefreshTaskID == taskID {
          self.environmentRefreshTask = nil
          self.environmentRefreshTaskID = nil
        }
      }

      guard let self else { throw CancellationError() }
      let environment = try await dependencies.transport.send(EnvironmentAPI.get()).value
      try Task.checkCancellation()
      try runtime.validateStableRuntime()
      clerk.applyRefreshedEnvironment(environment)
      return environment
    }

    tasks.track(task)
    environmentRefreshTask = task
    environmentRefreshTaskID = taskID
    return try await task.value
  }

  private func scheduleStartupEnvironmentRefresh() {
    let retryPolicy = Self.startupRefreshRetryPolicy
    tasks.task { @MainActor [weak self] in
      guard let self else { return }
      do {
        _ = try await retryingOperation(
          policy: retryPolicy,
          operationName: "environment refresh"
        ) {
          try await self.refreshEnvironment()
        }
      } catch is CancellationError {
        return
      } catch {
        ClerkLogger.logError(error, message: "Failed to load environment")
      }
    }
  }

  func startStartupClientRefreshIfNeeded() {
    guard startupClientRefreshTask == nil else { return }
    lifecycleClientRefresh = nil
    startupClientRefreshTask = clientRefreshForLifecycle(retryingStartup: true)
  }

  @discardableResult
  func cancelStartupClientRefreshTask() -> Bool {
    guard let startupClientRefreshTask else { return false }
    self.startupClientRefreshTask = nil
    startupClientRefreshTask.task.cancel()
    if lifecycleClientRefresh?.id == startupClientRefreshTask.id {
      lifecycleClientRefresh = nil
    }
    return true
  }

  func waitForClientRefresh() async throws -> Client? {
    try Task.checkCancellation()
    guard let clerk, let refresh = clientRefreshForLifecycle() else { throw CancellationError() }
    let scope = clerk.runtimeScope
    let waiter = ClientRefreshWaiter()
    let observation = Task { @MainActor in
      await waiter.resolve(refresh.task.result)
    }
    tasks.track(observation)
    defer { observation.cancel() }
    _ = try await withTaskCancellationHandler {
      try await waiter.value()
    } onCancel: {
      Task { @MainActor in waiter.resolve(.failure(CancellationError())) }
    }
    try Task.checkCancellation()
    try scope.validateStableRuntime()
    guard lifecycleClientRefresh?.id == refresh.id,
          lifecycleClientRefresh?.generation == clerk.clientResponseGeneration
    else {
      throw CancellationError()
    }
    return clerk.client
  }

  func invalidateLifecycleClientRefresh() {
    lifecycleClientRefresh = nil
  }

  func invalidateCompletedClientRefresh() {
    if lifecycleClientRefresh?.isCompleted == true {
      lifecycleClientRefresh = nil
    }
  }

  private func clientRefreshForLifecycle(retryingStartup: Bool = false) -> ClientRefresh? {
    guard let clerk else { return nil }
    let generation = clerk.clientResponseGeneration
    if let lifecycleClientRefresh, lifecycleClientRefresh.generation == generation {
      return lifecycleClientRefresh
    }

    let scope = clerk.runtimeScope
    let policy = retryingStartup
      ? Self.startupRefreshRetryPolicy
      : RetryPolicy(maxAttempts: 1, initialDelay: .zero, maximumDelay: .zero)
    let id = UUID()
    let task = Task { @MainActor [weak self, weak clerk] in
      defer {
        if self?.lifecycleClientRefresh?.id == id {
          self?.lifecycleClientRefresh?.isCompleted = true
        }
        if self?.startupClientRefreshTask?.id == id {
          self?.startupClientRefreshTask = nil
        }
      }
      do {
        guard let clerk else { throw CancellationError() }
        return try await retryingOperation(policy: policy, operationName: "client refresh") {
          try scope.validateStableRuntime()
          let fetched = try await clerk.fetchClient(skipClientId: false)
          guard let generation = fetched.generation else { throw CancellationError() }
          if self?.lifecycleClientRefresh?.id == id {
            self?.lifecycleClientRefresh?.generation = generation
          }
          return fetched.client
        }
      } catch {
        if self?.lifecycleClientRefresh?.id == id {
          self?.lifecycleClientRefresh = nil
        }
        if retryingStartup, !(error is CancellationError) {
          ClerkLogger.logError(error, message: "Failed to load client")
        }
        throw error
      }
    }
    tasks.track(task)
    let refresh = ClientRefresh(id: id, generation: generation, task: task)
    lifecycleClientRefresh = refresh
    return refresh
  }

  var isStartupClientRefreshInProgress: Bool {
    startupClientRefreshTask != nil
  }

  @discardableResult
  func cancelStartupClientRefresh() -> Bool {
    startupClientRefreshTakeover.cancel()
    return cancelStartupClientRefreshTask()
  }

  func refreshClientAfterInvalidAuth() async {
    let task = startRefreshClientAfterInvalidAuth()
    await task.value
  }

  func startRefreshClientAfterInvalidAuth() -> Task<Void, Never> {
    if let invalidAuthRefreshTask {
      return invalidAuthRefreshTask
    }

    let task = tasks.task { @MainActor [weak self] in
      defer { self?.invalidAuthRefreshTask = nil }

      guard let clerk = self?.clerk else { return }
      do {
        try await clerk.refreshClient()
      } catch {
        ClerkLogger.logError(error, message: "Failed to refresh client after invalid authentication response")
      }
    }

    invalidAuthRefreshTask = task
    return task
  }
}

extension ClerkRuntime: LifecycleEventHandling {
  func onWillEnterForeground() {
    guard let clerk else { return }
    if foregroundNeedsClientRefresh {
      invalidateLifecycleClientRefresh()
      foregroundNeedsClientRefresh = false
    }
    sessionPollingManager?.startPolling()

    clerk.identityController.adoptStoredDeviceToken()
    clerk.emitInternalStateChange(.applicationDidEnterForeground)

    #if os(macOS)
    if WebAuthentication.consumePendingForegroundRefreshSuppression() {
      return
    }
    #endif

    guard let refresh = clientRefreshForLifecycle() else { return }
    tasks.task { [weak self] in
      guard let self else { return }
      do {
        try Task.checkCancellation()
        _ = try await refresh.task.value
        try Task.checkCancellation()
      } catch is CancellationError {
        return
      } catch {
        ClerkLogger.logError(error, message: "Failed to refresh client on foreground")
      }

      await sessionPollingManager?.refreshNowIfNeeded()
    }

    tasks.task { [weak self] in
      guard let self else { return }
      do {
        _ = try await refreshEnvironment()
      } catch {
        ClerkLogger.logError(error, message: "Failed to refresh environment on foreground")
      }
    }
  }

  func onDidEnterBackground() {
    foregroundNeedsClientRefresh = true
    invalidateLifecycleClientRefresh()
    sessionPollingManager?.stopPolling()

    let telemetry = dependencies.telemetryCollector
    tasks.task(priority: .utility) {
      await telemetry.flush()
    }
  }
}
