import Combine
import Foundation

@testable import HoleberryCore

/// Configurable mock implementing `PiholeServerManaging` with stub injection and
/// call-count tracking.
@MainActor
final class MockPiholeServerManager: PiholeServerManaging {
  @Published var servers: [ServerConfig] = []
  var serversPublisher: Published<[ServerConfig]>.Publisher { $servers }

  var getBlockingStatusStub: [UUID: Result<BlockingStatus, PiholeError>] = [:]
  private(set) var getBlockingStatusCallCount = 0
  /// One-shot: the next `getBlockingStatus()` awaits this before returning.
  var getBlockingStatusGate: (@MainActor () async -> Void)?

  var setBlockingStub: [UUID: Bool] = [:]
  private(set) var setBlockingCallCount = 0
  var setBlockingLastEnabled: Bool?
  var setBlockingLastDuration: TimeInterval?

  var getQuerySummaryStub: [UUID: Result<QuerySummary, PiholeError>] = [:]
  private(set) var getQuerySummaryCallCount = 0
  var getQuerySummaryResponses: [[UUID: Result<QuerySummary, PiholeError>]] = []
  /// One-shot: runs inside `getQuerySummary()` after the last queued response.
  var getQuerySummaryGate: (@MainActor () async -> Void)?

  var updateGravityStub: [UUID: Result<Void, PiholeError>] = [:]
  private(set) var updateGravityCallCount = 0
  /// One-shot: the next `updateGravity()` awaits this before returning.
  var updateGravityGate: (@MainActor () async -> Void)?

  var getRecentBlockedStub: Result<[BlockedDomain], any Error> = .success([])
  private(set) var getRecentBlockedCallCount = 0
  private(set) var getRecentBlockedLastClientIp: String?

  func getBlockingStatus(scope: ServerScope) async -> [UUID: Result<BlockingStatus, PiholeError>] {
    getBlockingStatusCallCount += 1
    if let gate = getBlockingStatusGate {
      getBlockingStatusGate = nil
      await gate()
    }
    return scoped(getBlockingStatusStub, to: scope)
  }

  var checkServerStub: [UUID: Result<BlockingStatus, PiholeError>] = [:]
  private(set) var checkServerCallCount = 0
  private(set) var checkServerLastID: UUID?
  /// One-shot: the next `checkServer(id:)` awaits this before returning.
  var checkServerGate: (@MainActor () async -> Void)?

  func checkServer(id: UUID) async -> Result<BlockingStatus, PiholeError>? {
    checkServerCallCount += 1
    checkServerLastID = id
    if let gate = checkServerGate {
      checkServerGate = nil
      await gate()
    }
    return checkServerStub[id]
  }

  func setBlocking(enabled: Bool, duration: TimeInterval?) async -> [UUID: Bool] {
    setBlockingCallCount += 1
    setBlockingLastEnabled = enabled
    setBlockingLastDuration = duration
    return setBlockingStub
  }

  func getQuerySummary(scope: ServerScope) async -> [UUID: Result<QuerySummary, PiholeError>] {
    getQuerySummaryCallCount += 1
    if !getQuerySummaryResponses.isEmpty {
      let result = getQuerySummaryResponses.removeFirst()
      if getQuerySummaryResponses.isEmpty {
        if let gate = getQuerySummaryGate {
          getQuerySummaryGate = nil
          await gate()
        }
      }
      return scoped(result, to: scope)
    }
    return scoped(getQuerySummaryStub, to: scope)
  }

  private func scoped<Value>(
    _ results: [UUID: Result<Value, PiholeError>], to scope: ServerScope
  ) -> [UUID: Result<Value, PiholeError>] {
    switch scope {
    case .all:
      return results
    case .server(let id):
      guard servers.contains(where: { $0.id == id }) else {
        return [id: .failure(.unknown("Server not found"))]
      }
      return [id: results[id] ?? .failure(.unknown("Server not found"))]
    }
  }

  func updateGravity() async -> [UUID: Result<Void, PiholeError>] {
    updateGravityCallCount += 1
    if let gate = updateGravityGate {
      updateGravityGate = nil
      await gate()
    }
    return updateGravityStub
  }

  func getRecentBlocked(forClientIp: String?, interval: DateInterval) async throws -> [BlockedDomain] {
    getRecentBlockedCallCount += 1
    getRecentBlockedLastClientIp = forClientIp
    return try getRecentBlockedStub.get()
  }
}
