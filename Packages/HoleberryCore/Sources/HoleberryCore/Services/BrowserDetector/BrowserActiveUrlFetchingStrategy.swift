import Foundation

/// The app's access state for a browser. `.denied` names the System Settings
/// pane that restores access.
public enum BrowserAccessState: Equatable {
  /// Verified — or nothing to check (browser not installed).
  case allowed
  /// macOS has not asked yet — the consent dialog can still be shown.
  case notDetermined
  /// Access refused; this pane restores it.
  case denied(PermissionSettingsPane)
}

/// The System Settings pane that fixes a browser's denied access.
public enum PermissionSettingsPane: Equatable {
  /// Privacy & Security → Automation.
  case automation
  /// Privacy & Security → Files & Folders.
  case filesAndFolders
}

public protocol BrowserActiveUrlFetchingStrategy {
  /// The browser this strategy was built for. Fixed at construction by the
  /// factory, so no call site can pair a strategy with another browser.
  var browser: Browser { get }

  /// Returns the browser's current URL, or nil when unavailable.
  func getCurrentURL() -> URL?

  /// Silent probe — must never show a dialog.
  func accessState() -> BrowserAccessState

  /// Asks the OS to show its consent dialog, when this mechanism has one.
  /// The outcome is observable on the next `accessState()` probe.
  func requestAccess()
}
