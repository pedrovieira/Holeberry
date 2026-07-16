import AppKit
import Foundation
import OSLog

@MainActor
final class BrowserUrlFetcher {
  private let logger = Logger(subsystem: Logger.appSubsystem, category: "browser-url")
  private let strategyFactory = BrowserActiveUrlFetchingStrategyFactory()

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

    if isInternalPage(urlString) {
      return ""
    }

    let string = urlString.hasPrefix("http") ? urlString : "https://\(urlString)"
    guard let components = URLComponents(string: string),
      let host = components.host
    else { return "" }
    return host
  }

  private func isInternalPage(_ urlString: String) -> Bool {
    let lowercased = urlString.lowercased()
    let internalPrefixes = [
      "about:", "chrome:", "chrome-extension:", "edge:",
      "brave:", "opera:", "vivaldi:", "moz-extension:"
    ]
    for prefix in internalPrefixes where lowercased.hasPrefix(prefix) {
      return true
    }
    return false
  }
}
