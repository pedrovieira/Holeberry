import AppKit
import Foundation
import Testing

@testable import Holeberry

@MainActor
@Suite("AppFocusMonitor")
struct AppFocusMonitorTests {
  private let notificationCenter = NotificationCenter()

  private func makeMonitor() -> AppFocusMonitor {
    AppFocusMonitor(
      notificationCenter: notificationCenter
    ) { notification in
      notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? String
    }
  }

  // MARK: - Helpers

  private func postActivation(bundleID: String) {
    notificationCenter.post(
      name: NSWorkspace.didActivateApplicationNotification,
      object: nil,
      userInfo: [NSWorkspace.applicationUserInfoKey: bundleID]
    )
  }

  private func postTermination(bundleID: String) {
    notificationCenter.post(
      name: NSWorkspace.didTerminateApplicationNotification,
      object: nil,
      userInfo: [NSWorkspace.applicationUserInfoKey: bundleID]
    )
  }

  // MARK: - Activation

  @Test("Sets lastSeenBrowser when a known browser is activated")
  func knownBrowserActivation() async {
    let monitor = makeMonitor()

    postActivation(bundleID: Browser.chrome.bundleID)
    await Task.yield()

    #expect(monitor.lastSeenBrowser == .chrome)
  }

  @Test("Does not set lastSeenBrowser for a non-browser app")
  func nonBrowserActivation() async {
    let monitor = makeMonitor()

    postActivation(bundleID: "com.apple.Terminal")
    await Task.yield()

    #expect(monitor.lastSeenBrowser == nil)
  }

  @Test("Does not set lastSeenBrowser for an unknown bundle ID")
  func unknownBundleActivation() async {
    let monitor = makeMonitor()

    postActivation(bundleID: "com.unknown.FooBar")
    await Task.yield()

    #expect(monitor.lastSeenBrowser == nil)
  }

  @Test("Does not clear lastSeenBrowser when a non-browser app is focused")
  func nonBrowserActivationAfterBrowser() async {
    let monitor = makeMonitor()

    postActivation(bundleID: Browser.chrome.bundleID)
    await Task.yield()
    #expect(monitor.lastSeenBrowser == .chrome)

    postActivation(bundleID: "com.apple.Terminal")
    await Task.yield()

    #expect(monitor.lastSeenBrowser == .chrome)
  }

  @Test("Tracks the latest browser on sequential activations")
  func tracksLatestBrowser() async {
    let monitor = makeMonitor()

    postActivation(bundleID: Browser.chrome.bundleID)
    await Task.yield()
    #expect(monitor.lastSeenBrowser == .chrome)

    postActivation(bundleID: Browser.firefox.bundleID)
    await Task.yield()
    #expect(monitor.lastSeenBrowser == .firefox)

    postActivation(bundleID: Browser.safari.bundleID)
    await Task.yield()
    #expect(monitor.lastSeenBrowser == .safari)
  }

  // MARK: - Termination

  @Test("Clears lastSeenBrowser when the tracked browser terminates")
  func terminationOfTrackedBrowser() async {
    let monitor = makeMonitor()

    postActivation(bundleID: Browser.chrome.bundleID)
    await Task.yield()
    #expect(monitor.lastSeenBrowser == .chrome)

    postTermination(bundleID: Browser.chrome.bundleID)
    await Task.yield()

    #expect(monitor.lastSeenBrowser == nil)
  }

  @Test("Does not clear lastSeenBrowser when a different browser terminates")
  func terminationOfUntrackedBrowser() async {
    let monitor = makeMonitor()

    postActivation(bundleID: Browser.chrome.bundleID)
    await Task.yield()
    #expect(monitor.lastSeenBrowser == .chrome)

    postTermination(bundleID: Browser.firefox.bundleID)
    await Task.yield()

    #expect(monitor.lastSeenBrowser == .chrome)
  }

  @Test("Does nothing when an unknown bundle terminates and lastSeenBrowser is nil")
  func terminationWhenNoBrowserTracked() async {
    let monitor = makeMonitor()

    postTermination(bundleID: Browser.chrome.bundleID)
    await Task.yield()

    #expect(monitor.lastSeenBrowser == nil)
  }

  @Test("Posts with nil userInfo do not crash or change state")
  func nilUserInfoNotification() async {
    let monitor = makeMonitor()

    // Post without userInfo — extractor returns nil
    notificationCenter.post(
      name: NSWorkspace.didActivateApplicationNotification,
      object: nil
    )
    await Task.yield()

    #expect(monitor.lastSeenBrowser == nil)
  }
}
