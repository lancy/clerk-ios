//
//  LifecycleManagerTests.swift
//  Clerk
//
//  Created on 2025-01-27.
//

@testable import ClerkKit
import Foundation
import Testing

@MainActor
final class MockLifecycleHandler: LifecycleEventHandling {
  var foregroundCallCount = 0
  var backgroundCallCount = 0

  func onWillEnterForeground() {
    foregroundCallCount += 1
  }

  func onDidEnterBackground() {
    backgroundCallCount += 1
  }
}

@MainActor
@Suite(.serialized)
struct LifecycleManagerTests {
  @Test
  func deliversLifecycleEventsBeforePostingReturns() {
    let center = NotificationCenter()
    let handler = MockLifecycleHandler()
    let manager = LifecycleManager(handler: handler, notificationCenter: center)

    manager.startObserving()

    center.post(name: LifecycleManager.willEnterForegroundNotification, object: nil)
    #expect(handler.foregroundCallCount == 1)
    #expect(handler.backgroundCallCount == 0)

    center.post(name: LifecycleManager.didEnterBackgroundNotification, object: nil)
    #expect(handler.backgroundCallCount == 1)
    #expect(handler.foregroundCallCount == 1)

    manager.stopObserving()
  }

  @Test
  func testStopObserving() {
    let center = NotificationCenter()
    let handler = MockLifecycleHandler()
    let manager = LifecycleManager(handler: handler, notificationCenter: center)

    manager.startObserving()
    center.post(name: LifecycleManager.willEnterForegroundNotification, object: nil)
    #expect(handler.foregroundCallCount == 1)

    manager.stopObserving()

    postLifecycleNotifications(center)

    #expect(handler.foregroundCallCount == 1)
    #expect(handler.backgroundCallCount == 0)
  }

  @Test
  func multipleStartObserving() {
    let center = NotificationCenter()
    let handler = MockLifecycleHandler()
    let manager = LifecycleManager(handler: handler, notificationCenter: center)

    manager.startObserving()
    manager.startObserving()
    manager.startObserving()

    postLifecycleNotifications(center)

    #expect(handler.foregroundCallCount == 1)
    #expect(handler.backgroundCallCount == 1)

    manager.stopObserving()
  }

  @Test
  func stopObservingMultipleTimes() {
    let center = NotificationCenter()
    let handler = MockLifecycleHandler()
    let manager = LifecycleManager(handler: handler, notificationCenter: center)

    manager.startObserving()
    manager.stopObserving()
    manager.stopObserving()
    manager.stopObserving()

    postLifecycleNotifications(center)
    #expect(handler.foregroundCallCount == 0)
    #expect(handler.backgroundCallCount == 0)

    manager.startObserving()
    postLifecycleNotifications(center)
    #expect(handler.foregroundCallCount == 1)
    #expect(handler.backgroundCallCount == 1)

    manager.stopObserving()
  }

  @Test
  func releasedManagerStopsObserving() {
    let center = NotificationCenter()
    let handler = MockLifecycleHandler()
    weak var released: LifecycleManager?

    do {
      let manager = LifecycleManager(handler: handler, notificationCenter: center)
      released = manager
      manager.startObserving()
    }

    #expect(released == nil)

    postLifecycleNotifications(center)
    #expect(handler.foregroundCallCount == 0)
    #expect(handler.backgroundCallCount == 0)
  }

  private func postLifecycleNotifications(_ center: NotificationCenter) {
    center.post(name: LifecycleManager.willEnterForegroundNotification, object: nil)
    center.post(name: LifecycleManager.didEnterBackgroundNotification, object: nil)
  }
}
