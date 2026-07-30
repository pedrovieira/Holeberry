import AppKit
import Combine
import Foundation
import OSLog

/// Observes NSWorkspace notifications to track the last-seen browser.
/// The cache persists until a different browser is detected, the browser
/// is quit, or this object is deallocated.
public protocol AppFocusMonitoring: AnyObject, Sendable {
  @MainActor var lastSeenBrowser: Browser? { get }
}

public final class AppFocusMonitor: ObservableObject, AppFocusMonitoring, @unchecked Sendable {
  @MainActor @Published public private(set) var lastSeenBrowser: Browser?

  private var activationObserver: NSObjectProtocol?
  private var terminationObserver: NSObjectProtocol?
  private let logger = Logger(subsystem: Logger.appSubsystem, category: "app-focus")

  private let notificationCenter: NotificationCenter
  private let bundleIDExtractor: (Notification) -> String?

  public init(
    notificationCenter: NotificationCenter,
    bundleIDExtractor: @escaping (Notification) -> String?
  ) {
    self.notificationCenter = notificationCenter
    self.bundleIDExtractor = bundleIDExtractor

    activationObserver = notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification,
      object: nil,
      queue: .main
    ) { [weak self] notification in
      guard
        let self,
        let bundleID = self.bundleIDExtractor(notification),
        let browser = Browser(rawValue: bundleID)
      else { return }
      Task { @MainActor [weak self] in
        self?.lastSeenBrowser = browser
        self?.logger.debug("Browser detected: \(browser.appName) (\(bundleID, privacy: .public))")
      }
    }

    terminationObserver = notificationCenter.addObserver(
      forName: NSWorkspace.didTerminateApplicationNotification,
      object: nil,
      queue: .main
    ) { [weak self] notification in
      guard
        let self,
        let bundleID = self.bundleIDExtractor(notification)
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
    if let activationObserver { notificationCenter.removeObserver(activationObserver) }
    if let terminationObserver { notificationCenter.removeObserver(terminationObserver) }
  }
}
