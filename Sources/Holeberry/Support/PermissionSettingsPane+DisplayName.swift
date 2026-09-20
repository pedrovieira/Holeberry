import HoleberryCore

extension PermissionSettingsPane {
  /// Name of this permission's pane under Settings → Privacy & Security, e.g.
  /// "Files & Folders". Keep in sync with the OS copy.
  var displayName: String {
    switch self {
    case .automation: return "Automation"
    case .filesAndFolders: return "Files & Folders"
    }
  }
}
