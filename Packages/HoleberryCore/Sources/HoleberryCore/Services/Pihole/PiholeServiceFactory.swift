import Foundation

/// Builds an application-facing Pi-hole service for a given server configuration.
///
/// The factory owns the app-local temporary-unblock dependency, so a caller
/// chooses the construction mode once, not per build. Extracted so
/// `PiholeServerManager` depends on the seam and tests can inject a mock; the
/// production implementation is `ConcretePiholeServiceFactory`.
@MainActor
public protocol PiholeServiceFactory {
  func buildService(
    config: ServerConfig,
    credential: String,
    session: any HTTPRequestable
  ) throws -> any PiholeServiceProviding
}

/// Builds services for the app or for an on-demand read-only caller.
public struct ConcretePiholeServiceFactory: PiholeServiceFactory {
  private let authSessionFactory: any AuthSessionFactory
  private let tempUnblockStorage: (any TempUnblockStoring)?

  /// Application construction. Built services restore, reconcile, and save
  /// app-local temporary-unblock records.
  public init(
    authSessionFactory: any AuthSessionFactory,
    tempUnblockStorage: any TempUnblockStoring
  ) {
    self.authSessionFactory = authSessionFactory
    self.tempUnblockStorage = tempUnblockStorage
  }

  /// On-demand construction for short-lived read-only callers such as the widget.
  ///
  /// Built services hold no local persistence: they never restore, save, or
  /// reconcile temporary-unblock records, and no placeholder defaults store
  /// stands in for the app-local one.
  public init(onDemand authSessionFactory: any AuthSessionFactory) {
    self.authSessionFactory = authSessionFactory
    self.tempUnblockStorage = nil
  }

  public func buildService(
    config: ServerConfig,
    credential: String,
    session: any HTTPRequestable
  ) throws -> any PiholeServiceProviding {
    guard let url = URL(string: config.url) else {
      // Never echo the saved address or a secret here: the label is enough to
      // find the connection, and the text may reach logs and diagnostics.
      throw PiholeError.unknown("Saved server address is invalid")
    }

    let raw: any PiholeAPIProviding
    switch config.version {
    case .v6:
      let authSession = try authSessionFactory.makeSession(
        host: url, password: credential, urlSession: session, piHoleVersion: config.version
      )
      raw = PiholeV6Service(
        id: config.id,
        label: config.label,
        url: config.url,
        version: config.version,
        baseURL: url,
        urlSession: session,
        authSession: authSession
      )
    case .v5:
      raw = PiholeV5Service(
        id: config.id,
        label: config.label,
        url: config.url,
        version: config.version,
        baseURL: url,
        session: session,
        apiToken: credential
      )
    }
    // Every construction path keeps the decorator, so temporary-unblock
    // semantics are identical with and without local storage.
    return TemporaryUnblockPiholeServiceDecorator(
      service: raw, storage: tempUnblockStorage
    )
  }
}
