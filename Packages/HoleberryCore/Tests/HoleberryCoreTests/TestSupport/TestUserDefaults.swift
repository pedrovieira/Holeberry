import Foundation

/// Isolated in-memory `UserDefaults` for tests that must simulate a suite whose
/// `synchronize()` reports failure or whose writes are silently dropped while
/// typed reads and writes otherwise work normally.
final class TestUserDefaults: UserDefaults, @unchecked Sendable {
  /// Value returned by `synchronize()`. Never affects typed reads or writes.
  var synchronizeResult = true

  /// Keys whose writes are ignored, simulating a suite that fails to persist.
  var rejectedWriteKeys: Set<String> = []

  private var values: [String: Any] = [:]

  override func object(forKey defaultName: String) -> Any? {
    values[defaultName]
  }

  override func set(_ value: Any?, forKey defaultName: String) {
    guard !rejectedWriteKeys.contains(defaultName) else { return }
    values[defaultName] = value
  }

  override func removeObject(forKey defaultName: String) {
    values.removeValue(forKey: defaultName)
  }

  override func register(defaults registrationDictionary: [String: Any]) {}

  override func synchronize() -> Bool {
    synchronizeResult
  }
}
