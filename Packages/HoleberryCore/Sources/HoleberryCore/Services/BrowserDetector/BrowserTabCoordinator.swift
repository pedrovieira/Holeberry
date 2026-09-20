import AppKit
import Defaults
import Foundation
import OSLog

// MARK: - Protocol

@MainActor
public protocol BrowserTabCoordinating {
  func resolve() -> ResolvedBrowserTab
  func requestPermissionIfNeededAndResolve() -> ResolvedBrowserTab
  var lastSeenBrowser: Browser? { get }
}

/// Coordinates browser tab detection: tracks the last-seen browser via
/// AppFocusMonitor, checks its access state, and fetches the URL.
@MainActor
public final class BrowserTabCoordinator: BrowserTabCoordinating {
  private let monitor: any AppFocusMonitoring
  private let defaultsSuite: UserDefaults
  private let strategyFactory: any UrlFetchingStrategyFactory
  private let logger = Logger(subsystem: Logger.appSubsystem, category: "browser-tab")

  public init(
    monitor: any AppFocusMonitoring,
    strategyFactory: any UrlFetchingStrategyFactory,
    defaultsSuite: UserDefaults = .standard
  ) {
    self.monitor = monitor
    self.strategyFactory = strategyFactory
    self.defaultsSuite = defaultsSuite
  }

  // MARK: - Resolve (read-only)

  /// Resolves the current browser tab state without side effects.
  public func resolve() -> ResolvedBrowserTab {
    guard Defaults[.browserTabUnblockEnabled(suite: defaultsSuite)] else {
      return .disabled
    }

    guard let browser = monitor.lastSeenBrowser else {
      return .noBrowser
    }

    let strategy = strategyFactory.strategy(for: browser)
    switch strategy.accessState() {
    case .allowed:
      break
    case .notDetermined:
      return .permissionNeeded(browser)
    case .denied(let pane):
      return .permissionDenied(browser, pane)
    }

    guard let domain = strategy.getCurrentURL()?.domain else {
      return .noURL(browser)
    }
    return .url(browser, domain)
  }

  // MARK: - Request Permission & Resolve

  /// Shows the OS consent dialog when the state allows one, then resolves.
  /// `.notDetermined` is the only promptable state, and the strategy owns the
  /// mechanism that may fix it — this type never names one directly.
  public func requestPermissionIfNeededAndResolve() -> ResolvedBrowserTab {
    let result = resolve()
    guard case .permissionNeeded(let browser) = result else { return result }
    strategyFactory.strategy(for: browser).requestAccess()
    return resolve()
  }

  // MARK: - Browser Icon

  /// The last-seen browser from the app-focus monitor.
  public var lastSeenBrowser: Browser? { monitor.lastSeenBrowser }
}
