import AppKit
import Defaults
import Foundation
import OSLog

@MainActor
final class BrowserUrlFetcher {
  private let logger = Logger(subsystem: Logger.appSubsystem, category: "browser-url")
  private let strategyFactory = BrowserActiveUrlFetchingStrategyFactory()

  enum Status: Equatable {
    case disabled
    case noBrowser
    case permissionDenied
    case noURL
    case url(String)

    var isSuccess: Bool {
      if case .url = self { return true }
      return false
    }
  }

  func resolveCurrentTabDomain() -> Status {
    guard Defaults[.browserTabUnblockEnabled()] else {
      return .disabled
    }

    guard let frontApp = NSWorkspace.shared.frontmostApplication,
      let bundleID = frontApp.bundleIdentifier,
      let browser = Browser(rawValue: bundleID)
    else {
      return .noBrowser
    }

    let strategy = strategyFactory.strategy(for: browser)
    let result = strategy.getCurrentURL(for: browser)
    // nil means permission denied; empty means no URL available
    if result == nil {
      return .permissionDenied
    }
    let urlString = result.flatMap { $0.isEmpty ? nil : $0 }

    guard let urlString, let host = hostFromURL(urlString) else {
      return .noURL
    }

    if isInternalPage(urlString) {
      return .noURL
    }

    return .url(host)
  }

  private func hostFromURL(_ urlString: String) -> String? {
    let string = urlString.hasPrefix("http") ? urlString : "https://\(urlString)"
    guard let components = URLComponents(string: string),
      let host = components.host
    else { return nil }
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
