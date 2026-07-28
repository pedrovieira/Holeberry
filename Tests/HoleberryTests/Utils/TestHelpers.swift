import Defaults
import Foundation

/// Shared JSON encoder/decoder instances for tests.
/// Using a single instance avoids re-creating these lightweight but commonly-used objects.
enum TestJSON {
  static let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }()

  static let decoder = JSONDecoder()
}

/// Creates an isolated `UserDefaults` suite for a single test.
/// Each call returns a unique, pre-cleaned suite so parallel tests don't interfere.
enum TestDefaults {
  static func makeSuite() -> UserDefaults {
    let name = "com.holeberry.tests.\(UUID().uuidString)"
    guard let suite = UserDefaults(suiteName: name) else {
      fatalError("Failed to create test UserDefaults suite")
    }
    return suite
  }
}
