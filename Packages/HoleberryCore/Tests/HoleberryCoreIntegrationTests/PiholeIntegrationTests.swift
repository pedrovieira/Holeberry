import Foundation
import Testing

@testable import HoleberryCore

/// Opt-in, serialized integration scenarios.
///
/// The enabled condition only reads the opt-in flag. No configuration, transport,
/// defaults suite, process or network work happens at suite initialization, so a
/// plain package run compiles this target and skips it without Docker.
@Suite(
  .serialized,
  .enabled(if: ProcessInfo.processInfo.environment[IntegrationEnvironment.optInKey] == "1")
)
@MainActor
struct PiholeIntegrationTests {
  @Test func detectionV5() async throws {
    try await unimplemented("detectionV5")
  }

  @Test func detectionV6() async throws {
    try await unimplemented("detectionV6")
  }

  @Test func domainsV5() async throws {
    try await unimplemented("domainsV5")
  }

  @Test func domainsV6() async throws {
    try await unimplemented("domainsV6")
  }

  @Test func blockingV5() async throws {
    try await unimplemented("blockingV5")
  }

  @Test func blockingV6() async throws {
    try await unimplemented("blockingV6")
  }

  @Test func managedUnblockV5() async throws {
    try await unimplemented("managedUnblockV5")
  }

  @Test func managedUnblockV6() async throws {
    try await unimplemented("managedUnblockV6")
  }

  @Test func queryAndGravityV5() async throws {
    try await unimplemented("queryAndGravityV5")
  }

  @Test func queryAndGravityV6() async throws {
    try await unimplemented("queryAndGravityV6")
  }

  /// Validates the runtime configuration, then fails as a deliberate Task 3 stub.
  ///
  /// Missing or invalid configuration fails first, naming only the key or field.
  private func unimplemented(_ method: String) async throws {
    _ = try IntegrationEnvironment.load()
    throw IntegrationScenarioError.notImplemented(method)
  }
}

/// Deliberate staged failure for scenarios Task 4 replaces with real assertions.
enum IntegrationScenarioError: Error, LocalizedError, CustomStringConvertible, CustomDebugStringConvertible {
  case notImplemented(String)

  var errorDescription: String? {
    switch self {
    case .notImplemented(let method):
      return "Integration scenario \(method) is not implemented yet; Task 4 supplies its assertions."
    }
  }

  var description: String {
    errorDescription ?? "Integration scenario is not implemented yet."
  }

  var debugDescription: String {
    description
  }
}
