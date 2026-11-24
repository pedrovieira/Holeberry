import Foundation

/// Why a shared open returned no reader.
public enum SharedStorageAccessError: Error, Equatable, LocalizedError {
  /// The App Group holds no completed copy, so no list may be read yet.
  case copyNotPublished

  public var errorDescription: String? {
    switch self {
    case .copyNotPublished:
      return "Shared storage is not ready yet."
    }
  }
}

/// Opens the App Group copy for read-only callers such as the widget.
///
/// Each open resolves the current location and validates the current persisted
/// completion marker and server list, then returns a validated reader. Readiness,
/// the list outcome, and a credential reader are never cached across opens; the
/// injected `SharedStorageProviding` may cache successful handle resolutions.
@MainActor
public final class ConcreteSharedStorageReader: SharedStorageReading {
  private let sharedStorage: any SharedStorageProviding

  public init(sharedStorage: any SharedStorageProviding) {
    self.sharedStorage = sharedStorage
  }

  /// Opens a validated list reader. The widget picker needs the list and must not
  /// touch the credential store.
  public func openServerReader() throws -> any ServerReading {
    SharedServerReader(servers: try currentServers())
  }

  /// Opens a validated list reader and resolves the shared credential store after
  /// the list validates. A failed resolution throws; the next open retries it.
  public func openConnectionReader() throws -> any ConnectionReading {
    let servers = try currentServers()
    return SharedConnectionReader(servers: servers, keychain: try sharedStorage.keychain())
  }

  /// One open: current location, current completion marker, current list.
  private func currentServers() throws -> [ServerConfig] {
    let location = try sharedStorage.location()
    guard
      let servers = try SharedStorageValidation.completedServers(
        in: location.suite,
        suiteName: location.suiteName
      )
    else {
      throw SharedStorageAccessError.copyNotPublished
    }
    return servers
  }
}

/// A validated server list from one shared open.
///
/// The list is a snapshot, so one open decodes it once. Capabilities stop here:
/// this type reads no credentials and writes nothing.
public struct SharedServerReader: ServerReading {
  private let servers: [ServerConfig]

  init(servers: [ServerConfig]) {
    self.servers = servers
  }

  public func loadServers() -> [ServerConfig] { servers }
}

/// A validated server list and the shared credential store from one open.
///
/// Capabilities stop at reading: this type cannot write servers, credentials, or
/// temporary-unblock records, and it holds no app-local or legacy defaults.
public struct SharedConnectionReader: ConnectionReading {
  private let servers: [ServerConfig]
  private let keychain: any KeychainManaging

  init(servers: [ServerConfig], keychain: any KeychainManaging) {
    self.servers = servers
    self.keychain = keychain
  }

  public func loadServers() -> [ServerConfig] { servers }

  public func readCredential(for serverID: UUID) throws -> String? {
    try keychain.readCredential(for: serverID)
  }
}
