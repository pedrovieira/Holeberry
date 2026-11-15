import Foundation

@testable import HoleberryCore

/// Configurable mock implementing `KeychainManaging` for unit tests.
final class MockKeychainManager: KeychainManaging, @unchecked Sendable {
  /// Stored credentials keyed by server UUID string.
  var storedCredentials: [String: String] = [:]

  /// If non-nil, all operations throw this error.
  var errorStub: (any Error)?

  private(set) var saveCredentialCallCount = 0
  private(set) var readCredentialCallCount = 0
  private(set) var deleteCredentialCallCount = 0
  private(set) var lastSavedCredential: (credential: String, serverID: UUID)?
  private(set) var lastReadServerID: UUID?
  private(set) var lastDeletedServerID: UUID?

  func saveCredential(_ credential: String, for serverID: UUID) throws {
    saveCredentialCallCount += 1
    lastSavedCredential = (credential, serverID)
    if let errorStub { throw errorStub }
    storedCredentials[serverID.uuidString] = credential
  }

  func readCredential(for serverID: UUID) throws -> String? {
    readCredentialCallCount += 1
    lastReadServerID = serverID
    if let errorStub { throw errorStub }
    return storedCredentials[serverID.uuidString]
  }

  func deleteCredential(for serverID: UUID) throws {
    deleteCredentialCallCount += 1
    lastDeletedServerID = serverID
    if let errorStub { throw errorStub }
    storedCredentials.removeValue(forKey: serverID.uuidString)
  }
}
