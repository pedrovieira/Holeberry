import Foundation

protocol BrowserActiveUrlFetchingStrategy {
  /// Returns the current URL string from the browser, or nil if unavailable.
  func getCurrentURL(for browser: Browser) -> String?
}
