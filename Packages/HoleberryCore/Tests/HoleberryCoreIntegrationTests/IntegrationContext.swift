import Foundation

@testable import HoleberryCore

/// A failure raised while constructing an integration context.
enum IntegrationContextError: Error, LocalizedError, Equatable {
  case invalidLaneURL
  case defaultsSuiteUnavailable
  case closed

  var errorDescription: String? {
    switch self {
    case .invalidLaneURL:
      return "The validated integration lane URL could not be constructed."
    case .defaultsSuiteUnavailable:
      return "An isolated integration defaults suite could not be created."
    case .closed:
      return "The integration context is already closed."
    }
  }
}

/// Sanitized cleanup failures collected after every cleanup step was attempted.
struct IntegrationCleanupFailure: Error, LocalizedError, CustomStringConvertible, CustomDebugStringConvertible {
  let failures: [String]

  var errorDescription: String? {
    "Integration context cleanup failed: \(failures.joined(separator: "; "))"
  }

  var description: String {
    errorDescription ?? "Integration context cleanup failed."
  }

  var debugDescription: String {
    description
  }
}

/// Preserves an operation failure while reporting a secondary cleanup failure.
struct IntegrationOperationFailure: Error, LocalizedError, CustomStringConvertible, CustomDebugStringConvertible {
  let operationError: any Error
  let operationDescription: String
  let cleanupDescription: String

  var errorDescription: String? {
    "Integration operation failed: \(operationDescription); "
      + "cleanup also failed: \(cleanupDescription)"
  }

  var description: String {
    errorDescription ?? "Integration operation failed."
  }

  var debugDescription: String {
    description
  }
}

/// One isolated production-stack context for a single integration lane.
///
/// Owns a unique server identity, an isolated preferences suite, an ephemeral
/// transport and the factory-built service (already wrapped by the temporary
/// unblock decorator). Cleanup is explicit and best effort across every step.
@MainActor
final class IntegrationContext {
  let lane: IntegrationLane
  let config: ServerConfig
  let service: any PiholeServiceProviding
  let transport: IntegrationHTTPClient
  let defaults: UserDefaults

  private let defaultsSuiteName: String
  private let redactor: IntegrationRedactor
  private var blockingRestoration: Bool?
  private var ownedDomains: [OwnedDomain] = []
  private var isClosed = false

  private struct OwnedDomain {
    let domain: String
    let list: DomainListType
    let identity: String
  }

  private init(
    lane: IntegrationLane,
    config: ServerConfig,
    service: any PiholeServiceProviding,
    transport: IntegrationHTTPClient,
    defaults: UserDefaults,
    defaultsSuiteName: String,
    redactor: IntegrationRedactor
  ) {
    self.lane = lane
    self.config = config
    self.service = service
    self.transport = transport
    self.defaults = defaults
    self.defaultsSuiteName = defaultsSuiteName
    self.redactor = redactor
  }

  static func make(lane: IntegrationLane) async throws -> IntegrationContext {
    guard let url = URL(string: lane.url) else {
      throw IntegrationContextError.invalidLaneURL
    }

    let suiteName = "com.holeberry.integration.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
      throw IntegrationContextError.defaultsSuiteUnavailable
    }
    defaults.removePersistentDomain(forName: suiteName)

    let redactor = IntegrationRedactor(secrets: [lane.credential])
    let transport = IntegrationHTTPClient(lane: lane, redactor: redactor)
    let config = ServerConfig(id: UUID(), url: url.absoluteString, version: lane.version)

    do {
      let factory = ConcretePiholeServiceFactory(
        authSessionFactory: ConcreteAuthSessionFactory()
      )
      let service = try factory.buildService(
        config: config,
        credential: lane.credential,
        session: transport,
        suite: defaults
      )
      return IntegrationContext(
        lane: lane,
        config: config,
        service: service,
        transport: transport,
        defaults: defaults,
        defaultsSuiteName: suiteName,
        redactor: redactor
      )
    } catch {
      transport.invalidateAndCancel()
      defaults.removePersistentDomain(forName: suiteName)
      throw error
    }
  }

  /// Registers the blocking state to restore during close.
  ///
  /// Call this before the first future blocking mutation so cleanup never has to
  /// guess whether the fixture was originally blocking.
  func registerBlockingRestoration(enabled: Bool) throws {
    guard !isClosed else {
      throw IntegrationContextError.closed
    }
    blockingRestoration = enabled
  }

  /// Registers an entry created by this scenario so close removes only it.
  func registerOwnedDomain(_ domain: String, in list: DomainListType) throws {
    guard !isClosed else {
      throw IntegrationContextError.closed
    }
    let identity = PiholeDomain.identity(domain)
    guard !ownedDomains.contains(where: { $0.identity == identity && $0.list == list }) else {
      return
    }
    ownedDomains.append(OwnedDomain(domain: domain, list: list, identity: identity))
  }

  /// Forgets an entry the scenario already removed itself.
  func releaseOwnedDomain(_ domain: String, in list: DomainListType) {
    let identity = PiholeDomain.identity(domain)
    ownedDomains.removeAll { $0.identity == identity && $0.list == list }
  }

  /// Restores owned state, removes owned mutations, logs out, invalidates the
  /// transport and removes the isolated defaults domain.
  ///
  /// Every step runs even after an earlier failure. Failures are sanitized before
  /// being reported, and the context is considered closed either way.
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
        failures.append("restore blocking: \(sanitizedDescription(of: error))")
      }
    }

    for entry in ownedDomains.reversed() {
      do {
        try await service.deleteDomain(entry.domain, from: entry.list)
      } catch {
        failures.append(
          "remove \(String(describing: entry.list)) entry: \(sanitizedDescription(of: error))"
        )
      }
    }

    await service.logout()
    transport.invalidateAndCancel()
    defaults.removePersistentDomain(forName: defaultsSuiteName)

    if !failures.isEmpty {
      throw IntegrationCleanupFailure(failures: failures)
    }
  }

  /// Renders a production error safely for a test-framework failure message.
  func sanitizedDescription(of error: any Error) -> String {
    let raw: String
    if let localized = error as? any LocalizedError, let description = localized.errorDescription {
      raw = description
    } else {
      raw = String(describing: error)
    }
    return String(redactor.sanitize(raw).prefix(400))
  }
}

/// Runs one scenario against a freshly built context and always closes it.
///
/// The operation failure is preserved. If cleanup also fails, the operation
/// error stays attached to the secondary failure.
@MainActor
func withIntegrationContext(
  lane: IntegrationLane,
  operation: (IntegrationContext) async throws -> Void
) async throws {
  let context = try await IntegrationContext.make(lane: lane)
  do {
    try await operation(context)
  } catch {
    let operationError = error
    let operationDescription = context.sanitizedDescription(of: operationError)
    do {
      try await context.close()
    } catch {
      throw IntegrationOperationFailure(
        operationError: operationError,
        operationDescription: operationDescription,
        cleanupDescription: context.sanitizedDescription(of: error)
      )
    }
    throw operationError
  }
  try await context.close()
}
