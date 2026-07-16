import AppKit
import Defaults
import Foundation
import OSLog

/// The result of resolving the current browser tab state.
enum ResolvedBrowserTab: Equatable {
  case disabled
  case noBrowser
  case permissionNeeded(Browser)
  case permissionDenied(Browser)
  case noURL
  case url(Browser, String)
}

/// Coordinates browser tab detection: tracks the last-seen browser via
/// AppFocusMonitor, checks Automation permission, and fetches the URL.
@MainActor
final class BrowserTabCoordinator {
  private let monitor: AppFocusMonitor
  private let urlFetcher: BrowserUrlFetcher
  private let strategyFactory = BrowserActiveUrlFetchingStrategyFactory()
  private let logger = Logger(subsystem: Logger.appSubsystem, category: "browser-tab")

  init(monitor: AppFocusMonitor, urlFetcher: BrowserUrlFetcher) {
    self.monitor = monitor
    self.urlFetcher = urlFetcher
  }

  // MARK: - Resolve (read-only)

  /// Resolves the current browser tab state without side effects.
  func resolve() -> ResolvedBrowserTab {
    guard Defaults[.browserTabUnblockEnabled()] else {
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
      return .noURL
    }
    return .url(browser, domain)
  }

  // MARK: - Request Permission & Resolve

  /// Requests Automation permission (may show TCC dialog), then resolves.
  func requestPermissionAndResolve() -> ResolvedBrowserTab {
    guard Defaults[.browserTabUnblockEnabled()] else {
      return .disabled
    }

    guard let browser = monitor.lastSeenBrowser else {
      return .noBrowser
    }

    let strategy = strategyFactory.strategy(for: browser)
    strategy.requestPermission(for: browser)

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
      return .noURL
    }
    return .url(browser, domain)
  }

  // MARK: - Browser Icon

  func resolveBrowserIcon() -> NSImage? {
    guard let bundleID = monitor.lastSeenBrowser?.bundleID else { return nil }
    guard
      let app = NSRunningApplication.runningApplications(
        withBundleIdentifier: bundleID
      ).first
    else { return nil }
    return app.resizedIcon(size: NSRunningApplication.menuBarIconSize)
  }
}
