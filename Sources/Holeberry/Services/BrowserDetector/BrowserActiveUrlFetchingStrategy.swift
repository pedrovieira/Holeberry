import Foundation

/// The three distinct outcomes of querying TCC Automation permission.
enum AutomationPermission {
  case allowed
  case denied
  case notDetermined
}

protocol BrowserActiveUrlFetchingStrategy {
  /// Returns the current URL string from the browser, or nil if unavailable.
  func getCurrentURL(for browser: Browser) -> String?

  /// Checks whether Automation permission has been granted without showing a dialog.
  func isPermissionGranted(for browser: Browser) -> AutomationPermission

  /// Requests Automation permission, potentially showing the system TCC dialog.
  func requestPermission(for browser: Browser)
}
