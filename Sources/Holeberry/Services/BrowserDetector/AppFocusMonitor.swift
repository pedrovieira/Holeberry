import AppKit
import Combine
import Foundation
import OSLog

/// Observes NSWorkspace.didActivateApplicationNotification to track the
/// last-seen browser. Cache persists until a different browser is detected
/// or the app terminates.
@MainActor
final class AppFocusMonitor: ObservableObject {
  @Published private(set) var lastSeenBrowser: Browser?

  private var observer: NSObjectProtocol?
  private let logger = Logger(subsystem: Logger.appSubsystem, category: "app-focus")

  init() {
    observer = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification,
      object: nil,
      queue: .main
    ) { [weak self] notification in
      guard let self else { return }
      guard
        let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
          as? NSRunningApplication,
        let bundleID = app.bundleIdentifier,
        let browser = Browser(rawValue: bundleID)
      else {
        // Non-browser app: keep lastSeenBrowser unchanged
        return
      }
      self.lastSeenBrowser = browser
      self.logger.debug("Browser detected: \(browser.appName) (\(bundleID))")
    }
  }

  deinit {
    if let observer {
      NSWorkspace.shared.notificationCenter.removeObserver(observer)
    }
  }
}
