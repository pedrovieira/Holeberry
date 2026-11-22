import Foundation

/// Deep links shared by the app and widget targets.
///
/// The scheme mirrors `CFBundleURLSchemes` in the app's Info.plist, generated
/// from project.yml. Keep the scheme here and in project.yml in sync.
public enum AppDeepLink {
  /// URL scheme shared by every deep link the app handles.
  public static let scheme = "holeberry"

  /// Opens the settings window; widgets use it as their tap target.
  public static let settingsURL = URL(string: "\(scheme)://settings")

  /// Whether a URL targets the settings window.
  public static func isSettingsURL(_ url: URL) -> Bool {
    url.scheme?.lowercased() == scheme
      && url.host?.lowercased() == "settings"
      && url.user == nil && url.password == nil && url.port == nil
      && (url.path.isEmpty || url.path == "/")
      && url.query == nil && url.fragment == nil
  }
}
