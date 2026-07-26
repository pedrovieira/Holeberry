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
