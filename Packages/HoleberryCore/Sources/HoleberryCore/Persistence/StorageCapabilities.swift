import Foundation

/// Reads the saved server list.
///
/// The narrowest storage capability. A caller that only lists connections
/// cannot reach credentials or temporary-unblock records.
@MainActor
public protocol ServerReading {
  func loadServers() -> [ServerConfig]
}

/// Reads saved servers and their credentials.
@MainActor
public protocol ConnectionReading: ServerReading {
  /// - Returns: The saved credential, or `nil` when the server is passwordless.
  func readCredential(for serverID: UUID) throws -> String?
}

/// Writable connection storage: the saved list plus credentials.
///
/// Clearing a password and removing a connection are separate operations. The
/// first keeps the connection and its rollback copy; the second ends the
/// connection and cleans up after the migration.
@MainActor
public protocol ConnectionStoring: ConnectionReading {
  func saveServers(_ servers: [ServerConfig])
  func saveCredential(_ credential: String, for serverID: UUID) throws
  /// Deletes the active credential only. A migrated rollback copy stays.
  func deleteCredential(for serverID: UUID) throws
  /// Deletes the credential copies, then the saved configuration.
  func removeServer(id: UUID) throws
}

/// App-local temporary-unblock records.
///
/// Only the app stores these. An on-demand caller supplies no store, and the
/// temporary-unblock decorator then starts and saves nothing.
@MainActor
public protocol TempUnblockStoring {
  func loadTemporaryUnblocks(for serverID: UUID) -> [TempUnblockRecord]
  func saveTemporaryUnblocks(_ records: [TempUnblockRecord], for serverID: UUID)
}

/// Validated read access to the App Group copy shared with the widget.
///
/// Every call opens a validated reader over the current persistent domain again:
/// readiness and lists are not cached across opens. The injected provider may keep
/// successfully resolved suite and credential handles for the process. A reader
/// that must not prompt for credentials uses `openServerReader()`, which resolves
/// none.
@MainActor
public protocol SharedStorageReading {
  /// Opens the validated server list for one read. Resolves no credentials.
  func openServerReader() throws -> any ServerReading
  /// Opens the validated server list and the shared credential store for one read.
  func openConnectionReader() throws -> any ConnectionReading
}
