import Foundation

@testable import HoleberryCore

/// Configurable mock implementing `AppStorageProviding` with in-memory backing
/// state, Result stubs for throwing operations, and call tracking.
///
/// Nothing here touches real defaults or the real Keychain. A `nil` stub serves
/// the in-memory state; a stub, when set, wins and lets a test inject a failure.
@MainActor
final class MockAppStorage: AppStorageProviding {
  var servers: [ServerConfig] = []
  var credentials: [UUID: String] = [:]
  var temporaryUnblocks: [UUID: [TempUnblockRecord]] = [:]

  var readCredentialStub: Result<String?, any Error>?
  var saveCredentialStub: Result<Void, any Error>?
  var deleteCredentialStub: Result<Void, any Error>?

  private(set) var loadServersCallCount = 0
  private(set) var saveServersCallCount = 0
  private(set) var saveServersLastArgs: [ServerConfig]?

  private(set) var readCredentialCallCount = 0
  private(set) var readCredentialLastServerID: UUID?
  private(set) var saveCredentialCallCount = 0
  private(set) var saveCredentialLastArgs: (credential: String, serverID: UUID)?
  private(set) var deleteCredentialCallCount = 0
  private(set) var deleteCredentialLastServerID: UUID?

  private(set) var loadTemporaryUnblocksCallCount = 0
  private(set) var loadTemporaryUnblocksLastServerID: UUID?
  private(set) var saveTemporaryUnblocksCallCount = 0
  private(set) var saveTemporaryUnblocksLastArgs: (records: [TempUnblockRecord], serverID: UUID)?

  // MARK: - Server configurations

  func loadServers() -> [ServerConfig] {
    loadServersCallCount += 1
    return servers
  }

  func saveServers(_ servers: [ServerConfig]) {
    saveServersCallCount += 1
    saveServersLastArgs = servers
    self.servers = servers
  }

  func removeServer(id: UUID) throws {
    try deleteCredential(for: id)
    saveServers(servers.filter { $0.id != id })
  }

  // MARK: - Credentials

  func readCredential(for serverID: UUID) throws -> String? {
    readCredentialCallCount += 1
    readCredentialLastServerID = serverID
    if let stub = readCredentialStub {
      return try stub.get()
    }
    return credentials[serverID]
  }

  func saveCredential(_ credential: String, for serverID: UUID) throws {
    saveCredentialCallCount += 1
    saveCredentialLastArgs = (credential, serverID)
    if let stub = saveCredentialStub {
      try stub.get()
    }
    credentials[serverID] = credential
  }

  func deleteCredential(for serverID: UUID) throws {
    deleteCredentialCallCount += 1
    deleteCredentialLastServerID = serverID
    if let stub = deleteCredentialStub {
      try stub.get()
    }
    credentials.removeValue(forKey: serverID)
  }

  // MARK: - Temporary unblock records

  func loadTemporaryUnblocks(for serverID: UUID) -> [TempUnblockRecord] {
    loadTemporaryUnblocksCallCount += 1
    loadTemporaryUnblocksLastServerID = serverID
    return temporaryUnblocks[serverID] ?? []
  }

  func saveTemporaryUnblocks(_ records: [TempUnblockRecord], for serverID: UUID) {
    saveTemporaryUnblocksCallCount += 1
    saveTemporaryUnblocksLastArgs = (records, serverID)
    temporaryUnblocks[serverID] = records
  }
}
