import OSLog

extension Logger {
  static let appSubsystem = Bundle.main.bundleIdentifier ?? "com.pihole.menuapp"
}
