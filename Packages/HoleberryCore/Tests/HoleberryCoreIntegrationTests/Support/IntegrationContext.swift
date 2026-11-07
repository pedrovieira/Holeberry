import Foundation

@testable import HoleberryCore

enum IntegrationContextError: Error, LocalizedError, Equatable {
  case defaultsSuiteUnavailable
  case cleanupFailed([String])

  var errorDescription: String? {
    switch self {
    case .defaultsSuiteUnavailable:
      return "Could not create an isolated defaults suite for the integration test."
    case .cleanupFailed(let failures):
      return "Integration cleanup failed: \(failures.joined(separator: "; "))"
    }
  }
}

/// Preserves the test failure when cleanup also fails.
struct IntegrationOperationFailure: Error, LocalizedError {
  let operation: any Error
  let cleanup: any Error

  var errorDescription: String? {
    "Integration operation failed: \(operation.localizedDescription); "
      + "cleanup also failed: \(cleanup.localizedDescription)"
  }
}

/// One production-stack context for a single integration lane.
///
/// Owns an isolated defaults suite, a real ephemeral URL session and the
/// factory-built service (already wrapped by the temporary-unblock decorator).
@MainActor
final class IntegrationContext {
  let target: IntegrationTarget
  let config: ServerConfig
  let service: any PiholeServiceProviding
  let defaults: UserDefaults
  let session: URLSession
  let cli: ContainerCLI

  private let defaultsSuiteName: String
  private var blockingRestoration: Bool?
  private var ownedDomains: [(domain: String, list: DomainListType)] = []
  private var isClosed = false

  var version: ServerVersion {
    target.version
  }

  var container: ContainerService {
    target.container
  }

  var baseURL: URL {
    URL(string: config.url)!
  }

  private init(
    target: IntegrationTarget,
    config: ServerConfig,
    service: any PiholeServiceProviding,
    defaults: UserDefaults,
    session: URLSession,
    defaultsSuiteName: String,
    cli: ContainerCLI
  ) {
    self.target = target
    self.config = config
    self.service = service
    self.defaults = defaults
    self.session = session
    self.defaultsSuiteName = defaultsSuiteName
    self.cli = cli
  }

  static func make(
    target: IntegrationTarget,
    cli: ContainerCLI = ContainerCLI()
  ) async throws -> IntegrationContext {
    let baseURL = try IntegrationEnvironment.baseURL(for: target)
    let suiteName = "com.holeberry.integration.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
      throw IntegrationContextError.defaultsSuiteUnavailable
    }
    defaults.removePersistentDomain(forName: suiteName)

    let credential: String
    switch target {
    case .v5:
      credential = try await cli.v5Token()
    case .v6:
      credential = IntegrationEnvironment.v6Password
    case .v6Open:
      credential = ""
    }

    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 30
    configuration.timeoutIntervalForResource = 960
    configuration.httpCookieAcceptPolicy = .never
    configuration.httpShouldSetCookies = false
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    let session = URLSession(configuration: configuration)

    let config = ServerConfig(
      url: baseURL.absoluteString,
      version: target.version
    )

    do {
      let service = try ConcretePiholeServiceFactory(
        authSessionFactory: ConcreteAuthSessionFactory()
      ).buildService(
        config: config,
        credential: credential,
        session: session,
        suite: defaults,
        executionMode: .application
      )
      return IntegrationContext(
        target: target,
        config: config,
        service: service,
        defaults: defaults,
        session: session,
        defaultsSuiteName: suiteName,
        cli: cli
      )
    } catch {
      session.invalidateAndCancel()
      defaults.removePersistentDomain(forName: suiteName)
      throw error
    }
  }

  /// Call before the first blocking mutation so cleanup can restore it.
  func registerBlockingRestoration(enabled: Bool) {
    blockingRestoration = enabled
  }

  /// Registers an entry this test creates so cleanup removes only that entry.
  func registerOwnedDomain(_ domain: String, in list: DomainListType) {
    let identity = PiholeDomain.identity(domain)
    guard !ownedDomains.contains(where: { $0.domain == identity && $0.list == list }) else {
      return
    }
    ownedDomains.append((identity, list))
  }

  /// Resolves a domain through the container's DNS server, independent of the app client.
  func dig(_ domain: String) async throws -> String {
    try await cli.run(container, "dig", "+short", "@127.0.0.1", domain, "A")
  }

  /// Reads an exact list through the Pi-hole CLI, independent of the app client.
  func cliList(_ list: DomainListType) async throws -> String {
    switch (version, list) {
    case (.v5, .allow):
      return try await cli.run(container, "pihole", "-w", "-l")
    case (.v5, .deny):
      return try await cli.run(container, "pihole", "-b", "-l")
    case (.v6, .allow):
      return try await cli.run(container, "pihole", "allow", "-l")
    case (.v6, .deny):
      return try await cli.run(container, "pihole", "deny", "-l")
    }
  }

  /// Restores blocking, removes owned entries, closes the session and deletes
  /// the isolated defaults domain. Every step runs even after a failure.
  func close() async throws {
    guard !isClosed else {
      return
    }
    isClosed = true

    var failures: [String] = []

    if let restoration = blockingRestoration {
      do {
        try await service.setBlocking(enabled: restoration, duration: nil)
      } catch {
        failures.append("restore blocking: \(error.localizedDescription)")
      }
    }

    for entry in ownedDomains.reversed() {
      do {
        try await service.deleteDomain(entry.domain, from: entry.list)
      } catch {
        failures.append("remove \(entry.domain): \(error.localizedDescription)")
      }
    }

    await service.logout()
    session.invalidateAndCancel()
    defaults.removePersistentDomain(forName: defaultsSuiteName)

    if !failures.isEmpty {
      throw IntegrationContextError.cleanupFailed(failures)
    }
  }
}

/// Runs one scenario against a fresh context and always closes it.
@MainActor
func withContext(
  _ target: IntegrationTarget,
  _ operation: (IntegrationContext) async throws -> Void
) async throws {
  let context = try await IntegrationContext.make(target: target)
  do {
    try await operation(context)
  } catch {
    let operationError = error
    do {
      try await context.close()
    } catch {
      throw IntegrationOperationFailure(operation: operationError, cleanup: error)
    }
    throw operationError
  }
  try await context.close()
}
