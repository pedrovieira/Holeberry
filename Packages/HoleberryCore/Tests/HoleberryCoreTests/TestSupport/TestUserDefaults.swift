import Foundation

/// Isolated in-memory `UserDefaults` for tests that must simulate a suite whose
/// `synchronize()` reports failure, whose writes are silently dropped, or whose
/// registered defaults mask an absent persisted value.
final class TestUserDefaults: UserDefaults, @unchecked Sendable {
  /// Domain name used by `persistentDomain(forName:)` checks.
  let domainName = "com.holeberry.tests.\(UUID().uuidString)"

  /// Value returned by `synchronize()`. Never affects typed reads or writes.
  var synchronizeResult = true

  /// Keys whose writes are ignored, simulating a suite that fails to persist.
  var rejectedWriteKeys: Set<String> = []

  private var values: [String: Any] = [:]
  private var registeredValues: [String: Any] = [:]

  override func object(forKey defaultName: String) -> Any? {
    values[defaultName] ?? registeredValues[defaultName]
  }

  override func set(_ value: Any?, forKey defaultName: String) {
    guard !rejectedWriteKeys.contains(defaultName) else { return }
    values[defaultName] = value
  }

  override func removeObject(forKey defaultName: String) {
    values.removeValue(forKey: defaultName)
  }

  override func register(defaults registrationDictionary: [String: Any]) {
    registeredValues.merge(registrationDictionary) { _, new in new }
  }

  override func persistentDomain(forName domainName: String) -> [String: Any]? {
    guard domainName == self.domainName else { return nil }
    return values
  }

  override func synchronize() -> Bool {
    synchronizeResult
  }
}
