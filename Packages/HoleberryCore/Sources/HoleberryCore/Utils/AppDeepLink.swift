import Foundation

/// Deep links the app advertises through `CFBundleURLSchemes`.
///
/// The app and every widget target compile against these values, so the scheme
/// is defined once instead of drifting between call sites.
public enum AppDeepLink {
  /// URL scheme shared by every deep link the app handles.
  public static let scheme = "holeberry"

  /// Opens the settings window; widgets use it as their tap target.
  public static let settingsURL = URL(string: "\(scheme)://settings")
}
