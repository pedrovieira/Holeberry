import Combine
import Foundation

@testable import HoleberryCore

/// Configurable mock implementing `PiholeServerManaging` with stub injection and
/// call-count tracking.
@MainActor
final class MockPiholeServerManager: PiholeServerManaging {
  @Published var servers: [ServerConfig] = []
  var serversPublisher: Published<[ServerConfig]>.Publisher { $servers }

  var getBlockingStatusStub: [UUID: BlockingStatus?] = [:]
  private(set) var getBlockingStatusCallCount = 0
  /// One-shot: the next `getBlockingStatus()` awaits this before returning.
  var getBlockingStatusGate: (@MainActor () async -> Void)?

  var setBlockingStub: [UUID: Bool] = [:]
  private(set) var setBlockingCallCount = 0
  var setBlockingLastEnabled: Bool?
  var setBlockingLastDuration: TimeInterval?

  var getQuerySummaryStub: [UUID: QuerySummary?] = [:]
  private(set) var getQuerySummaryCallCount = 0

  var getRecentBlockedStub: Result<[BlockedDomain], any Error> = .success([])
  private(set) var getRecentBlockedCallCount = 0
  private(set) var getRecentBlockedLastClientIp: String?

  func getBlockingStatus() async -> [UUID: BlockingStatus?] {
    getBlockingStatusCallCount += 1
    if let gate = getBlockingStatusGate {
      getBlockingStatusGate = nil
      await gate()
    }
    return getBlockingStatusStub
  }

  func setBlocking(enabled: Bool, duration: TimeInterval?) async -> [UUID: Bool] {
    setBlockingCallCount += 1
    setBlockingLastEnabled = enabled
    setBlockingLastDuration = duration
    return setBlockingStub
  }

  func getQuerySummary() async -> [UUID: QuerySummary?] {
    getQuerySummaryCallCount += 1
    return getQuerySummaryStub
  }

  func getRecentBlocked(forClientIp: String?, interval: DateInterval) async throws -> [BlockedDomain] {
    getRecentBlockedCallCount += 1
    getRecentBlockedLastClientIp = forClientIp
    return try getRecentBlockedStub.get()
  }
}
