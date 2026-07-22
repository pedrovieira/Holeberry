import AppKit
import Combine
import Foundation
import OSLog

/// Observes NSWorkspace notifications to track the last-seen browser.
/// The cache persists until a different browser is detected, the browser
/// is quit, or this object is deallocated.
protocol AppFocusMonitoring: AnyObject, Sendable {
  @MainActor var lastSeenBrowser: Browser? { get }
}

final class AppFocusMonitor: ObservableObject, AppFocusMonitoring, @unchecked Sendable {
  @MainActor @Published private(set) var lastSeenBrowser: Browser?

  private var activationObserver: NSObjectProtocol?
  private var terminationObserver: NSObjectProtocol?
  private let logger = Logger(subsystem: Logger.appSubsystem, category: "app-focus")

  init() {
    let center = NSWorkspace.shared.notificationCenter

    activationObserver = center.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification,
      object: nil,
      queue: .main
    ) { [weak self] notification in
      guard
        let self,
        let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
          as? NSRunningApplication,
        let bundleID = app.bundleIdentifier,
        let browser = Browser(rawValue: bundleID)
      else {
        return
      }
      Task { @MainActor [weak self] in
        self?.lastSeenBrowser = browser
        self?.logger.debug("Browser detected: \(browser.appName) (\(bundleID, privacy: .public))")
      }
    }

    terminationObserver = center.addObserver(
      forName: NSWorkspace.didTerminateApplicationNotification,
      object: nil,
      queue: .main
    ) { [weak self] notification in
      guard
        let self,
        let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
          as? NSRunningApplication,
        let bundleID = app.bundleIdentifier
      else { return }

      Task { @MainActor [weak self] in
        guard let self else { return }
        if self.lastSeenBrowser?.bundleID == bundleID {
          self.lastSeenBrowser = nil
          self.logger.debug("Browser terminated: \(bundleID)")
        }
      }
    }
  }

  deinit {
    let center = NSWorkspace.shared.notificationCenter
    if let activationObserver { center.removeObserver(activationObserver) }
    if let terminationObserver { center.removeObserver(terminationObserver) }
  }
}
