import HoleberryCore

extension AuthFailureReason {
  /// Subtitle copy shown under the server name when authentication fails.
  /// Localized here, in the app layer — never in the package.
  var subtitleText: String {
    switch self {
    case .passwordMayHaveChanged:
      return String(localized: "Password may have changed")
    case .authenticationFailed:
      return String(localized: "Authentication failed")
    case .totpRequired:
      return String(localized: "TOTP required — use an app password")
    case .rateLimited:
      return String(localized: "Login rate limited — try again later")
    case .sessionLimitReached:
      return String(localized: "Session limit reached — sign out elsewhere")
    }
  }
}
