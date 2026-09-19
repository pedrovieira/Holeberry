import Foundation
import HoleberryCore

extension PermissionSettingsPane {
  /// Deep link into the System Settings pane where the user can grant or fix
  /// this permission.
  var systemSettingsURL: URL? {
    switch self {
    case .automation:
      // The pre-Ventura id (`com.apple.preference.security`) only opens the
      // Privacy & Security pane; anchors must be `Privacy_*` names.
      return URL(
        string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Automation"
      )
    case .filesAndFolders:
      // macOS 27+ app-data toggles live under the `Privacy_AppContainer` anchor.
      return URL(
        string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AppContainer"
      )
    }
  }
}
