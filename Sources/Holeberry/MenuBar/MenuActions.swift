import Foundation

/// Pure-data contract between `MenuBarController` and `MenuBuilder`:
/// every action the app menu can trigger, expressed as closures.
struct MenuActions {
  var openAppSettings: () -> Void
  var checkForUpdates: () -> Void

  /// `nil` duration = indefinitely.
  var disableBlocking: (TimeInterval?) -> Void
  var reEnableBlocking: () -> Void
  var triggerGravityUpdate: () -> Void

  var disableURL: (String, TimeInterval) -> Void
  var addToAllowlist: (String) -> Void

  var enableBrowserPermission: () -> Void
  var openAutomationSettings: () -> Void
}
