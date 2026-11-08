import Foundation

@testable import HoleberryCore

/// Configurable mock implementing `KeychainManaging` for unit tests.
final class MockKeychainManager: KeychainManaging, @unchecked Sendable {
  /// Stored credentials keyed by server UUID string.
  var storedCredentials: [String: String] = [:]

  /// If non-nil, all operations throw this error.
  var errorStub: (any Error)?

  /// Operation-specific failures checked before `errorStub`.
  var saveErrorStub: (any Error)?
  var readErrorStub: (any Error)?
  var deleteErrorStub: (any Error)?

  /// One-shot override for `readCredential`, used to simulate readback mismatches.
  var readResultOverride: Result<String?, any Error>?

  private(set) var saveCallCount = 0
  private(set) var readCallCount = 0
  private(set) var deleteCallCount = 0

  func saveCredential(_ credential: String, for serverID: UUID) throws {
    saveCallCount += 1
    if let saveErrorStub { throw saveErrorStub }
    if let errorStub { throw errorStub }
    storedCredentials[serverID.uuidString] = credential
  }

  func readCredential(for serverID: UUID) throws -> String? {
    readCallCount += 1
    if let readResultOverride {
      self.readResultOverride = nil
      return try readResultOverride.get()
    }
    if let readErrorStub { throw readErrorStub }
    if let errorStub { throw errorStub }
    return storedCredentials[serverID.uuidString]
  }

  func deleteCredential(for serverID: UUID) throws {
    deleteCallCount += 1
    if let deleteErrorStub { throw deleteErrorStub }
    if let errorStub { throw errorStub }
    storedCredentials.removeValue(forKey: serverID.uuidString)
  }
}
