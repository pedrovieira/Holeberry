import Foundation
import HoleberryCore

/// Pure-data contract between `MenuBarController` and `MenuBuilder`:
/// every action the app menu can trigger, expressed as closures.
enum DomainActionSource {
  case browserTab
  case recentlyBlocked
}

struct DomainMenuAction {
  let domain: String
  let duration: TimeInterval?
  let source: DomainActionSource
}

struct MenuActions {
  var openAppSettings: () -> Void
  var checkForUpdates: () -> Void

  /// `nil` duration = indefinitely.
  var disableBlocking: (TimeInterval?) -> Void
  var reEnableBlocking: () -> Void
  var triggerGravityUpdate: () -> Void

  var disableURL: (String, TimeInterval, DomainActionSource) -> Void
  var addToAllowlist: (String, DomainActionSource) -> Void

  var enableBrowserPermission: () -> Void

  /// Opens the System Settings pane that fixes the browser's permission state.
  var openBrowserPermissionSettings: (PermissionSettingsPane) -> Void
}
