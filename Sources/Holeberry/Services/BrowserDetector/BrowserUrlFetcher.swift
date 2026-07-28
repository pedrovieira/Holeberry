import AppKit
import Foundation
import OSLog

// MARK: - Protocol

@MainActor
protocol BrowserUrlFetching {
  func resolveCurrentTabDomain(for browser: Browser) -> String?
}

// MARK: - Concrete Implementation

@MainActor
final class BrowserUrlFetcher: BrowserUrlFetching {
  private let logger = Logger(subsystem: Logger.appSubsystem, category: "browser-url")
  private let strategyFactory: UrlFetchingStrategyFactory

  init(strategyFactory: UrlFetchingStrategyFactory) {
    self.strategyFactory = strategyFactory
  }

  /// Resolves the current tab domain for the given browser.
  /// - Returns: `nil` if permission denied, `""` if no URL available,
  ///   or a domain string on success.
  func resolveCurrentTabDomain(for browser: Browser) -> String? {
    let strategy = strategyFactory.strategy(for: browser)
    let result = strategy.getCurrentURL(for: browser)
    // nil means permission denied; empty means no URL available
    guard let urlString = result, !urlString.isEmpty else {
      return result  // nil → permission denied, "" → no URL
    }

    // Non-http URLs are internal browser pages (about:, chrome:, etc.)
    guard urlString.lowercased().hasPrefix("http://") || urlString.lowercased().hasPrefix("https://") else {
      return ""
    }

    guard let components = URLComponents(string: urlString),
      let host = components.host
    else { return "" }
    return host
  }
}
