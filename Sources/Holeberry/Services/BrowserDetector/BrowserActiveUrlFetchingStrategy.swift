import Foundation

protocol BrowserActiveUrlFetchingStrategy {
  /// Returns the current URL string from the browser, or nil if unavailable.
  func getCurrentURL(for browser: Browser) -> String?

  /// Checks whether Automation permission has been granted without showing a dialog.
  func isPermissionGranted(for browser: Browser) -> Bool

  /// Requests Automation permission, potentially showing the system TCC dialog.
  func requestPermission(for browser: Browser)
}
