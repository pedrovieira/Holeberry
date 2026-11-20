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

  /// Per-server save failures, used to simulate a failure partway through a
  /// multi-server migration.
  var saveErrorsByServerID: [UUID: any Error] = [:]

  private(set) var saveCallCount = 0
  private(set) var readCallCount = 0
  private(set) var deleteCallCount = 0

  var saveCredentialCallCount: Int { saveCallCount }
  var readCredentialCallCount: Int { readCallCount }
  var deleteCredentialCallCount: Int { deleteCallCount }
  private(set) var lastSavedCredential: (credential: String, serverID: UUID)?
  private(set) var lastReadServerID: UUID?
  private(set) var lastDeletedServerID: UUID?

  func saveCredential(_ credential: String, for serverID: UUID) throws {
    saveCallCount += 1
    lastSavedCredential = (credential, serverID)
    if let error = saveErrorsByServerID[serverID] { throw error }
    if let saveErrorStub { throw saveErrorStub }
    if let errorStub { throw errorStub }
    storedCredentials[serverID.uuidString] = credential
  }

  func readCredential(for serverID: UUID) throws -> String? {
    readCallCount += 1
    lastReadServerID = serverID
    if let readErrorStub { throw readErrorStub }
    if let errorStub { throw errorStub }
    return storedCredentials[serverID.uuidString]
  }

  func deleteCredential(for serverID: UUID) throws {
    deleteCallCount += 1
    lastDeletedServerID = serverID
    if let deleteErrorStub { throw deleteErrorStub }
    if let errorStub { throw errorStub }
    storedCredentials.removeValue(forKey: serverID.uuidString)
  }
}
