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

  var getQuerySummaryStub: [UUID: QuerySummary?] = [:]
  private(set) var getQuerySummaryCallCount = 0
  var getQuerySummaryResponses: [[UUID: QuerySummary?]] = []
  /// One-shot: runs inside `getQuerySummary()` after the last queued response.
  var getQuerySummaryGate: (@MainActor () async -> Void)?

  var updateGravityStub: [UUID: Result<Void, PiholeError>] = [:]
  private(set) var updateGravityCallCount = 0
  /// One-shot: the next `updateGravity()` awaits this before returning.
  var updateGravityGate: (@MainActor () async -> Void)?

  var getRecentBlockedStub: Result<[BlockedDomain], any Error> = .success([])
  private(set) var getRecentBlockedCallCount = 0
  private(set) var getRecentBlockedLastClientIp: String?

  var displayLabelStub: [UUID: String] = [:]
  private(set) var displayLabelArgs: [UUID] = []

  var getDomainQueryHistoryStub: [String: [UUID: Result<DomainQueryHistory, PiholeError>]] = [:]
  var getDomainQueryHistoryHandler:
    (([String], String, DateInterval, Set<UUID>) async -> [String: [UUID: Result<DomainQueryHistory, PiholeError>]])?
  var getDomainQueryHistoryGate: (@MainActor () async -> Void)?
  private(set) var getDomainQueryHistoryCallCount = 0
  private(set) var getDomainQueryHistoryLastDomains: [String]?
  private(set) var getDomainQueryHistoryLastClientIP: String?
  private(set) var getDomainQueryHistoryLastInterval: DateInterval?
  private(set) var getDomainQueryHistoryLastServerIDs: Set<UUID>?

  var applyDomainUnblockStub: [UUID: Result<DomainUnblockOutcome?, PiholeError>] = [:]
  var applyDomainUnblockHandler:
    ((String, TimeInterval?, Set<UUID>, DomainUnblockMode) async -> [UUID: Result<DomainUnblockOutcome?, PiholeError>])?
  private(set) var applyDomainUnblockCallCount = 0
  private(set) var applyDomainUnblockArgs:
    [(domain: String, duration: TimeInterval?, serverIDs: Set<UUID>, mode: DomainUnblockMode)] = []

  func displayLabel(for id: UUID) -> String? {
    displayLabelArgs.append(id)
    if let stub = displayLabelStub[id] { return stub }
    guard let server = servers.first(where: { $0.id == id }) else { return nil }
    return server.label ?? URL(string: server.url)?.host ?? server.url
  }

  func getDomainQueryHistory(
    domains: [String], forClientIP: String, interval: DateInterval
  ) async -> [String: [UUID: Result<DomainQueryHistory, PiholeError>]] {
    let serverIDs = Set(servers.map(\.id))
    getDomainQueryHistoryCallCount += 1
    getDomainQueryHistoryLastDomains = domains
    getDomainQueryHistoryLastClientIP = forClientIP
    getDomainQueryHistoryLastInterval = interval
    getDomainQueryHistoryLastServerIDs = serverIDs
    if let gate = getDomainQueryHistoryGate {
      getDomainQueryHistoryGate = nil
      await gate()
    }
    if let getDomainQueryHistoryHandler {
      return await getDomainQueryHistoryHandler(domains, forClientIP, interval, serverIDs)
    }
    return getDomainQueryHistoryStub.mapValues { $0.filter { serverIDs.contains($0.key) } }
  }

  func applyDomainUnblock(
    domain: String, duration: TimeInterval?, mode: DomainUnblockMode
  ) async -> [UUID: Result<DomainUnblockOutcome?, PiholeError>] {
    let serverIDs = Set(servers.map(\.id))
    applyDomainUnblockCallCount += 1
    applyDomainUnblockArgs.append((domain, duration, serverIDs, mode))
    if let applyDomainUnblockHandler {
      return await applyDomainUnblockHandler(domain, duration, serverIDs, mode)
    }
    return applyDomainUnblockStub.filter { serverIDs.contains($0.key) }
  }

  func getBlockingStatus() async -> [UUID: Result<BlockingStatus, PiholeError>] {
    getBlockingStatusCallCount += 1
    if let gate = getBlockingStatusGate {
      getBlockingStatusGate = nil
      await gate()
    }
    return getBlockingStatusStub
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

  func getQuerySummary() async -> [UUID: QuerySummary?] {
    getQuerySummaryCallCount += 1
    if !getQuerySummaryResponses.isEmpty {
      let result = getQuerySummaryResponses.removeFirst()
      if getQuerySummaryResponses.isEmpty {
        if let gate = getQuerySummaryGate {
          getQuerySummaryGate = nil
          await gate()
        }
      }
      return result
    }
    return getQuerySummaryStub
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
