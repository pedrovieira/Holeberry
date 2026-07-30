import AppKit
import Defaults
import Foundation
import OSLog

/// The result of resolving the current browser tab state.
public enum ResolvedBrowserTab: Equatable {
  case disabled
  case noBrowser
  case permissionNeeded(Browser)
  case permissionDenied(Browser)
  case noURL(Browser)
  case url(Browser, String)

  public var browser: Browser? {
    switch self {
    case .permissionNeeded(let browser): return browser
    case .permissionDenied(let browser): return browser
    case .noURL(let browser): return browser
    case .url(let browser, _): return browser
    case .disabled, .noBrowser: return nil
    }
  }
}

// MARK: - Protocol

@MainActor
public protocol BrowserTabCoordinating {
  func resolve() -> ResolvedBrowserTab
  func requestPermissionIfNeededAndResolve() -> ResolvedBrowserTab
  var lastSeenBrowser: Browser? { get }
}

/// Coordinates browser tab detection: tracks the last-seen browser via
/// AppFocusMonitor, checks Automation permission, and fetches the URL.
@MainActor
public final class BrowserTabCoordinator: BrowserTabCoordinating {
  private let monitor: AppFocusMonitoring
  private let urlFetcher: BrowserUrlFetching
  private let defaultsSuite: UserDefaults
  private let strategyFactory: UrlFetchingStrategyFactory
  private let logger = Logger(subsystem: Logger.appSubsystem, category: "browser-tab")

  public init(
    monitor: AppFocusMonitoring,
    urlFetcher: BrowserUrlFetching,
    strategyFactory: UrlFetchingStrategyFactory,
    defaultsSuite: UserDefaults = .standard
  ) {
    self.monitor = monitor
    self.urlFetcher = urlFetcher
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
    switch strategy.isPermissionGranted(for: browser) {
    case .allowed:
      break
    case .denied:
      return .permissionDenied(browser)
    case .notDetermined:
      return .permissionNeeded(browser)
    }

    let domain = urlFetcher.resolveCurrentTabDomain(for: browser)
    guard let domain, !domain.isEmpty else {
      return .noURL(browser)
    }
    return .url(browser, domain)
  }

  // MARK: - Request Permission & Resolve

  /// Requests Automation permission if needed (may show TCC dialog), then resolves.
  public func requestPermissionIfNeededAndResolve() -> ResolvedBrowserTab {
    let result = resolve()
    switch result {
    case .permissionNeeded(let browser), .permissionDenied(let browser):
      strategyFactory.strategy(for: browser).requestPermission(for: browser)
      return resolve()
    default:
      return result
    }
  }

  // MARK: - Browser Icon

  /// The last-seen browser from the app-focus monitor.
  public var lastSeenBrowser: Browser? { monitor.lastSeenBrowser }
}
