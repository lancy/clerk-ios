@_spi(FrameworkIntegration) @testable import ClerkKit
import Foundation
import Testing

@MainActor
@Suite(.serialized)
struct ClientRefreshTests {
  @Test
  func startupAndFirstForegroundShareTheNetworkResultInsteadOfTheCachedClient() async throws {
    let gate = ResponseGate()
    var cached = Client.mockSignedOut
    cached.id = "cached-client"
    var fresh = Client.mockSignedOut
    fresh.id = "fresh-client"
    let transport = FakeTransport.answeringClient {
      gate.open("requested")
      await gate.wait("response")
      return fresh
    }
    let clerk = try makeClerk(transport: transport, cached: cached)
    defer {
      gate.open("response")
      clerk.cleanupManagers()
    }
    #expect(clerk.isLoaded)
    #expect(clerk.client?.id == cached.id)
    await gate.wait("requested")

    let first = Task { try await clerk.waitForClientRefresh() }
    let second = Task { try await clerk.waitForClientRefresh() }
    defer {
      first.cancel()
      second.cancel()
    }
    clerk.runtime.onWillEnterForeground()
    gate.open("response")

    #expect(try await first.value?.id == fresh.id)
    #expect(try await second.value?.id == fresh.id)
    #expect(clientRequests(transport) == 1)
  }

  @Test
  func firstForegroundAndLateWaitersReuseTheCompletedStartupRefresh() async throws {
    let transport = FakeTransport.answeringClient { .mockSignedOut }
    let clerk = try makeClerk(transport: transport)
    defer { clerk.cleanupManagers() }
    _ = try await clerk.waitForClientRefresh()

    clerk.runtime.onWillEnterForeground()
    _ = try await clerk.waitForClientRefresh()
    _ = try await clerk.waitForClientRefresh()

    #expect(clientRequests(transport) == 1)
  }

  @Test
  func theAutomaticResponseCanEstablishItsOwnDeviceTokenWithoutAnotherRefresh() async throws {
    let transport = FakeTransport.mockDefaults()
    let clerk = try makeClerk(transport: transport)
    defer { clerk.cleanupManagers() }
    let client = Client.mockSignedOut
    transport.stubReply(ClientAPI.get()) { _ in
      try await clerk.identityController.applyNetworkResponse(ClientSyncResponseContext(
        update: .client(client),
        deviceTokenUpdate: .set("response-device-token"),
        requestDeviceToken: nil,
        serverDate: nil,
        isCanonicalClientRequest: true,
        clientResponseGeneration: clerk.clientResponseGeneration,
        responseSequence: 1
      ))
      return .init(ClientResponse(response: client, client: nil), requestSequence: 1)
    }

    #expect(try await clerk.waitForClientRefresh()?.id == client.id)
    #expect(clerk.deviceToken == "response-device-token")
    clerk.runtime.onWillEnterForeground()
    #expect(try await clerk.waitForClientRefresh()?.id == client.id)
    #expect(clientRequests(transport) == 1)
  }

  @Test
  func anExplicitRefreshDoesNotReplaceThePendingAutomaticRefresh() async throws {
    let gate = ResponseGate()
    let transport = FakeTransport.mockDefaults()
    var request = 0
    transport.stubReply(ClientAPI.get()) { _ in
      request += 1
      let sequence = request
      var client = Client.mockSignedOut
      client.id = "client-\(sequence)"
      if sequence == 1 {
        gate.open("startup-requested")
        await gate.wait("startup-response")
      }
      return .init(ClientResponse(response: client, client: nil), requestSequence: sequence)
    }
    let clerk = try makeClerk(transport: transport)
    defer {
      gate.open("startup-response")
      clerk.cleanupManagers()
    }
    await gate.wait("startup-requested")
    #expect(try await clerk.refreshClient()?.id == "client-2")

    clerk.runtime.onWillEnterForeground()
    gate.open("startup-response")
    #expect(try await clerk.waitForClientRefresh()?.id == "client-2")
    #expect(clientRequests(transport) == 2)
  }

  @Test
  func anAutomaticRefreshWithNoClientStillCompletes() async throws {
    let transport = FakeTransport.answeringClient { nil }
    let clerk = try makeClerk(transport: transport)
    defer { clerk.cleanupManagers() }
    #expect(try await clerk.waitForClientRefresh() == nil)

    clerk.runtime.onWillEnterForeground()
    #expect(try await clerk.waitForClientRefresh() == nil)
    #expect(clientRequests(transport) == 1)
  }

  @Test
  func backgroundInvalidatesTheCompletedResultForTheNextForeground() async throws {
    var request = 0
    let transport = FakeTransport.answeringClient {
      request += 1
      var client = Client.mockSignedOut
      client.id = "client-\(request)"
      return client
    }
    let clerk = try makeClerk(transport: transport)
    defer { clerk.cleanupManagers() }
    #expect(try await clerk.waitForClientRefresh()?.id == "client-1")

    clerk.runtime.onDidEnterBackground()
    clerk.runtime.onWillEnterForeground()
    #expect(try await clerk.waitForClientRefresh()?.id == "client-2")
    #expect(try await clerk.waitForClientRefresh()?.id == "client-2")
    #expect(clientRequests(transport) == 2)
  }

  @Test
  func aFailedRefreshIsNotCompletedByTheCachedClientAndCanBeRetriedOnForeground() async throws {
    let failure = ClerkAPIError(code: "test_rejected", message: "Client refresh rejected", statusCode: 403)
    let transport = FakeTransport.answeringClient { throw failure }
    let clerk = try makeClerk(transport: transport, cached: .mockSignedOut)
    defer { clerk.cleanupManagers() }

    await #expect(throws: ClerkAPIError.self) { try await clerk.waitForClientRefresh() }
    #expect(clientRequests(transport) == 1)

    transport.stub(ClientAPI.get(), returning: ClientResponse(response: Client.mockSignedOut, client: nil))
    clerk.runtime.onWillEnterForeground()
    #expect(try await clerk.waitForClientRefresh()?.id == Client.mockSignedOut.id)
    #expect(clientRequests(transport) == 2)
    #expect(try await clerk.waitForClientRefresh()?.id == Client.mockSignedOut.id)
    #expect(clientRequests(transport) == 2)
    #expect(try await clerk.refreshClient()?.id == Client.mockSignedOut.id)
    #expect(clientRequests(transport) == 3)
  }

  @Test
  func concurrentWaitersReceiveTheSameRefreshFailure() async throws {
    let gate = ResponseGate()
    let failure = ClerkAPIError(code: "test_rejected", message: "Client refresh rejected", statusCode: 403)
    let transport = FakeTransport.answeringClient {
      gate.open("requested")
      await gate.wait("response")
      throw failure
    }
    let clerk = try makeClerk(transport: transport)
    defer {
      gate.open("response")
      clerk.cleanupManagers()
    }
    let first = Task {
      gate.open("first-waiter")
      return try await clerk.waitForClientRefresh()
    }
    let second = Task {
      gate.open("second-waiter")
      return try await clerk.waitForClientRefresh()
    }
    defer {
      first.cancel()
      second.cancel()
    }
    await gate.wait("requested")
    await gate.wait("first-waiter")
    await gate.wait("second-waiter")
    gate.open("response")

    await #expect(throws: ClerkAPIError.self) { try await first.value }
    await #expect(throws: ClerkAPIError.self) { try await second.value }
    #expect(clientRequests(transport) == 1)
  }

  @Test
  func foregroundDoesNotJoinARequestStartedBeforeTheBackgroundTransition() async throws {
    let gate = ResponseGate()
    let transport = FakeTransport.mockDefaults()
    var request = 0
    transport.stubReply(ClientAPI.get()) { _ in
      request += 1
      let sequence = request
      var client = Client.mockSignedOut
      client.id = "client-\(sequence)"
      if sequence == 1 {
        gate.open("old-requested")
        await gate.wait("old-response")
      }
      return .init(ClientResponse(response: client, client: nil), requestSequence: sequence)
    }
    let clerk = try makeClerk(transport: transport)
    defer {
      gate.open("old-response")
      clerk.cleanupManagers()
    }
    let original = Task {
      gate.open("old-waiter")
      return try await clerk.waitForClientRefresh()
    }
    defer { original.cancel() }
    await gate.wait("old-requested")
    await gate.wait("old-waiter")

    clerk.runtime.onDidEnterBackground()
    clerk.runtime.onWillEnterForeground()
    #expect(try await clerk.waitForClientRefresh()?.id == "client-2")
    gate.open("old-response")
    await #expect(throws: CancellationError.self) { try await original.value }
    #expect(clerk.client?.id == "client-2")
    #expect(clientRequests(transport) == 2)
  }

  @Test
  func cancelingOneWaiterDoesNotCancelTheSDKOwnedRefresh() async throws {
    let gate = ResponseGate()
    let transport = FakeTransport.answeringClient {
      gate.open("requested")
      await gate.wait("response")
      return .mockSignedOut
    }
    let clerk = try makeClerk(transport: transport)
    defer {
      gate.open("response")
      clerk.cleanupManagers()
    }
    await gate.wait("requested")
    let canceled = Task {
      gate.open("waiter-started")
      return try await clerk.waitForClientRefresh()
    }
    let remaining = Task { try await clerk.waitForClientRefresh() }
    defer {
      canceled.cancel()
      remaining.cancel()
    }
    await gate.wait("waiter-started")
    canceled.cancel()
    await #expect(throws: CancellationError.self) { try await canceled.value }

    gate.open("response")
    #expect(try await remaining.value?.id == Client.mockSignedOut.id)
    #expect(clientRequests(transport) == 1)
  }

  @Test
  func aNewDeviceIdentityDoesNotReuseTheCompletedRefresh() async throws {
    var request = 0
    let transport = FakeTransport.answeringClient {
      request += 1
      var client = Client.mockSignedOut
      client.id = "client-\(request)"
      return client
    }
    let clerk = try makeClerk(transport: transport)
    defer { clerk.cleanupManagers() }
    #expect(try await clerk.waitForClientRefresh()?.id == "client-1")

    #expect(try await clerk.setDeviceToken("replacement-token", expected: nil))
    #expect(try await clerk.waitForClientRefresh()?.id == "client-2")
    #expect(clientRequests(transport) == 2)
  }

  @Test
  func aNewDeviceIdentityDoesNotJoinAnOlderInFlightRefresh() async throws {
    let gate = ResponseGate()
    var request = 0
    let transport = FakeTransport.answeringClient {
      request += 1
      var client = Client.mockSignedOut
      client.id = "client-\(request)"
      if request == 1 {
        gate.open("old-requested")
        await gate.wait("old-response")
      }
      return client
    }
    let clerk = try makeClerk(transport: transport)
    defer {
      gate.open("old-response")
      clerk.cleanupManagers()
    }
    let original = Task {
      gate.open("old-waiter-started")
      return try await clerk.waitForClientRefresh()
    }
    defer { original.cancel() }
    await gate.wait("old-requested")
    await gate.wait("old-waiter-started")
    #expect(try await clerk.setDeviceToken("replacement-token", expected: nil))
    #expect(try await clerk.waitForClientRefresh()?.id == "client-2")
    gate.open("old-response")
    await #expect(throws: CancellationError.self) { try await original.value }

    #expect(clerk.client?.id == "client-2")
    #expect(clientRequests(transport) == 2)
  }

  @Test
  func anOldResponseDoesNotCompleteTheNewIdentityRefreshFromCachedData() async throws {
    let gate = ResponseGate()
    var request = 0
    let transport = FakeTransport.answeringClient {
      request += 1
      var client = Client.mockSignedOut
      client.id = "client-\(request)"
      if request == 1 {
        gate.open("old-requested")
        await gate.wait("old-response")
      }
      return client
    }
    let clerk = try makeClerk(transport: transport)
    defer {
      gate.open("old-response")
      clerk.cleanupManagers()
    }
    let original = Task {
      gate.open("old-waiter")
      return try await clerk.waitForClientRefresh()
    }
    defer { original.cancel() }
    await gate.wait("old-requested")
    await gate.wait("old-waiter")
    #expect(try await clerk.setDeviceToken("replacement-token", expected: nil))
    gate.open("old-response")

    await #expect(throws: CancellationError.self) { try await original.value }
    #expect(clerk.client == nil)
    #expect(try await clerk.waitForClientRefresh()?.id == "client-2")
    #expect(clientRequests(transport) == 2)
  }

  @Test
  func stoppingTheRuntimeCancelsTheRefreshBeforeItCanPublish() async throws {
    let gate = ResponseGate()
    let transport = FakeTransport.answeringClient {
      gate.open("requested")
      await gate.wait("response")
      return .mockSignedOut
    }
    let clerk = try makeClerk(transport: transport)
    defer {
      gate.open("response")
      clerk.cleanupManagers()
    }
    let waiter = Task {
      gate.open("waiter-started")
      return try await clerk.waitForClientRefresh()
    }
    defer { waiter.cancel() }
    await gate.wait("requested")
    await gate.wait("waiter-started")
    clerk.cleanupManagers()
    gate.open("response")

    await #expect(throws: CancellationError.self) { try await waiter.value }
    #expect(clerk.client == nil)
    #expect(clientRequests(transport) == 1)
  }

  private func makeClerk(transport: FakeTransport, cached: Client? = nil) throws -> Clerk {
    let clerk = Clerk()
    let dependencies = MockDependencyContainer(
      apiClient: createMockAPIClient(runtimeScope: clerk.runtimeScope),
      transport: transport
    )
    if let cached {
      try dependencies.identityStore.save(ClerkIdentitySnapshot(
        state: .present,
        deviceToken: "cached-device-token",
        client: cached,
        serverDate: nil
      ))
    }
    clerk.performConfiguration(dependencies: dependencies)
    clerk.environment = .mock
    return clerk
  }

  private func clientRequests(_ transport: FakeTransport) -> Int {
    transport.calls.filter { $0.method == .get && $0.path == "/v1/client" }.count
  }
}
