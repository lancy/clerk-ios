//
//  LifecycleManager.swift
//  Clerk
//
//  Created on 2025-01-27.
//

import Foundation

#if os(watchOS)
import WatchKit
#elseif canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

protocol LifecycleEventHandling: Sendable {
  @MainActor func onWillEnterForeground()

  @MainActor func onDidEnterBackground()
}

/// Manages app lifecycle notifications and coordinates foreground/background transitions.
@MainActor
final class LifecycleManager {
  private var observations: [NotificationRegistration] = []

  private let handler: any LifecycleEventHandling

  private let notificationCenter: NotificationCenter

  init(
    handler: any LifecycleEventHandling,
    notificationCenter: NotificationCenter = .default
  ) {
    self.handler = handler
    self.notificationCenter = notificationCenter
  }

  func startObserving() {
    stopObserving()
    observations = [
      NotificationRegistration(center: notificationCenter, name: Self.willEnterForegroundNotification) { [weak self] in
        self?.handler.onWillEnterForeground()
      },
      NotificationRegistration(center: notificationCenter, name: Self.didEnterBackgroundNotification) { [weak self] in
        self?.handler.onDidEnterBackground()
      },
    ]
  }

  func stopObserving() {
    observations.removeAll()
  }
}

private final class NotificationRegistration {
  private let center: NotificationCenter
  private let token: NSObjectProtocol

  init(center: NotificationCenter, name: Notification.Name, operation: @escaping @MainActor @Sendable () -> Void) {
    self.center = center
    // System lifecycle notifications arrive on the UI thread, before scene-phase consumers.
    token = center.addObserver(forName: name, object: nil, queue: nil) { _ in
      MainActor.assumeIsolated { operation() }
    }
  }

  deinit {
    center.removeObserver(token)
  }
}

extension LifecycleManager {
  static var willEnterForegroundNotification: Notification.Name {
    #if os(macOS)
    NSApplication.didBecomeActiveNotification
    #elseif os(watchOS)
    WKApplication.willEnterForegroundNotification
    #else
    UIApplication.willEnterForegroundNotification
    #endif
  }

  static var didEnterBackgroundNotification: Notification.Name {
    #if os(macOS)
    NSApplication.didResignActiveNotification
    #elseif os(watchOS)
    WKApplication.didEnterBackgroundNotification
    #else
    UIApplication.didEnterBackgroundNotification
    #endif
  }
}
