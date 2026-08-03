import Foundation

@testable import HoleberryCore

/// Configurable mock implementing `KeychainManaging` for unit tests.
final class MockKeychainManager: KeychainManaging, @unchecked Sendable {
  /// Stored credentials keyed by server UUID string.
  var storedCredentials: [String: String] = [:]

  /// If non-nil, all operations throw this error.
  var errorStub: (any Error)?

  func saveCredential(_ credential: String, for serverID: UUID) throws {
    if let errorStub { throw errorStub }
    storedCredentials[serverID.uuidString] = credential
  }

  func readCredential(for serverID: UUID) throws -> String? {
    if let errorStub { throw errorStub }
    return storedCredentials[serverID.uuidString]
  }

  func deleteCredential(for serverID: UUID) throws {
    if let errorStub { throw errorStub }
    storedCredentials.removeValue(forKey: serverID.uuidString)
  }
}
