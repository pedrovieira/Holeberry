import Foundation
import Testing

@testable import HoleberryCore

@MainActor
@Suite("Browser domain unblock workflow")
struct BrowserDomainUnblockerTests {
  private let now = Date(timeIntervalSince1970: 1_700_000_000)
  private let clientIP = "192.168.1.50"

  @Test func capturesScopeAndSkipsOnlyAllowedHostname() async throws {
    let (manager, _, workflow) = makeWorkflow()
    let ids = Set(manager.servers.map(\.id))
    let first = try #require(manager.servers.first?.id)
    manager.displayLabelStub[first] = "Kitchen"
    manager.getDomainQueryHistoryStub["example.com"]?[first] = .success(history(.ruleBlocked))
    for id in ids {
      manager.getDomainQueryHistoryStub["www.example.com"]?[id] = .success(
        history(.permitted, domain: "www.example.com"))
    }
    manager.applyDomainUnblockHandler = { _, _, serverIDs in
      Dictionary(uniqueKeysWithValues: serverIDs.map { ($0, .success(.added)) })
    }

    let result = await workflow.unblock(domain: "www.example.com", duration: 300)

    #expect(result.outcome == .processed)
    #expect(result.requestedDomain == "www.example.com")
    #expect(result.candidateDomains == ["example.com", "www.example.com"])
    #expect(result.allowedDomains == ["www.example.com"])
    #expect(result.clientIP == clientIP)
    #expect(result.serverLabels[first] == "Kitchen")
    #expect(Set(result.serverLabels.keys) == ids)
    #expect(manager.getDomainQueryHistoryLastDomains == result.candidateDomains)
    #expect(manager.getDomainQueryHistoryLastClientIP == clientIP)
    #expect(manager.getDomainQueryHistoryLastInterval == DateInterval(start: now.addingTimeInterval(-900), end: now))
    #expect(manager.getDomainQueryHistoryLastServerIDs == ids)
    #expect(manager.applyDomainUnblockArgs.map(\.domain) == ["example.com"])
    #expect(result.mutations["www.example.com"] == nil)
    #expect(manager.applyDomainUnblockArgs.allSatisfy { $0.duration == 300 && $0.serverIDs == ids })
    #expect(try result.checks["example.com"]?[first]?.get() == .blocked)
    #expect(try result.checks["www.example.com"]?[first]?.get() == .notBlocked)
  }

  @Test func bothBlockedHostnamesAreMutatedIndependently() async throws {
    let (manager, _, workflow) = makeWorkflow()
    let id = try #require(manager.servers.first?.id)
    for domain in ["example.com", "www.example.com"] {
      manager.getDomainQueryHistoryStub[domain]?[id] = .success(history(.ruleBlocked, domain: domain))
    }
    manager.applyDomainUnblockStub[id] = .success(.added)

    let result = await workflow.unblock(domain: "EXAMPLE.COM.", duration: nil)

    #expect(result.outcome == .processed)
    #expect(manager.applyDomainUnblockCallCount == 2)
    #expect(manager.applyDomainUnblockArgs.map(\.domain) == ["example.com", "www.example.com"])
    #expect(manager.applyDomainUnblockArgs.allSatisfy { $0.duration == nil })
    #expect(result.mutations.count == 2)
  }

  @Test(arguments: [DomainQueryHandling.ruleBlocked, .upstreamBlocked, .inconclusive])
  func nonAllowEvidenceUnblocksNormally(handling: DomainQueryHandling) async throws {
    let (manager, _, workflow) = makeWorkflow()
    for id in manager.servers.map(\.id) {
      manager.getDomainQueryHistoryStub["example.com"]?[id] = .success(history(handling))
    }
    let result = await workflow.unblock(domain: "example.com", duration: 300)
    #expect(result.outcome == .processed)
    #expect(manager.applyDomainUnblockCallCount == 2)
  }

  @Test func noHistoryUnblocksNormally() async {
    let (manager, _, workflow) = makeWorkflow()
    let result = await workflow.unblock(domain: "example.com", duration: 60)
    #expect(result.outcome == .processed)
    #expect(manager.applyDomainUnblockCallCount == 2)
    #expect(result.checks.count == 2)
    #expect(result.allowedDomains.isEmpty)
  }

  @Test func allowedQueriesSkipRenewalAndPromotion() async {
    for outcome in [DomainUnblockOutcome.renewed, .promoted] {
      let (manager, _, workflow) = makeWorkflow()
      for domain in ["example.com", "www.example.com"] {
        for id in manager.servers.map(\.id) {
          manager.getDomainQueryHistoryStub[domain]?[id] = .success(history(.permitted, domain: domain))
          manager.applyDomainUnblockStub[id] = .success(outcome)
        }
      }
      let result = await workflow.unblock(domain: "example.com", duration: outcome == .promoted ? nil : 1800)
      #expect(result.outcome == .notBlocked)
      #expect(manager.applyDomainUnblockCallCount == 0)
      #expect(result.mutations.isEmpty)
    }
  }

  @Test func existingSiblingCannotHideAllowedDiagnostic() async {
    let (manager, _, workflow) = makeWorkflow()
    for domain in ["example.com", "www.example.com"] {
      for id in manager.servers.map(\.id) {
        manager.getDomainQueryHistoryStub[domain]?[id] = .success(history(.permitted, domain: domain))
      }
    }
    manager.applyDomainUnblockHandler = { _, _, ids in
      Dictionary(
        uniqueKeysWithValues: ids.map {
          ($0, .success(.alreadyPresent(enabled: true)))
        })
    }
    let result = await workflow.unblock(domain: "example.com", duration: 60)
    #expect(result.outcome == .notBlocked)
    #expect(result.allowedDomains == ["example.com", "www.example.com"])
    #expect(manager.applyDomainUnblockCallCount == 0)
  }

  @Test func busySiblingCannotHideAllowedDiagnostic() async {
    let (manager, _, workflow) = makeWorkflow()
    for id in manager.servers.map(\.id) {
      manager.getDomainQueryHistoryStub["example.com"]?[id] = .success(history(.permitted))
    }
    manager.applyDomainUnblockHandler = { _, _, ids in
      Dictionary(
        uniqueKeysWithValues: ids.map {
          ($0, .success(.inProgress))
        })
    }
    let result = await workflow.unblock(domain: "example.com", duration: 60)
    #expect(result.outcome == .notBlocked)
    #expect(result.allowedDomains == ["example.com"])
  }

  enum OtherServerEvidence: CaseIterable {
    case noHistory, failed, incomplete, missing
  }

  @Test func allowOnSingleServerSkipsAllMutations() async throws {
    let (manager, _, workflow) = makeWorkflow()
    manager.servers.removeLast()
    let id = try #require(manager.servers.first?.id)
    for domain in ["example.com", "www.example.com"] {
      manager.getDomainQueryHistoryStub[domain]?[id] = .success(history(.permitted, domain: domain))
    }

    let result = await workflow.unblock(domain: "example.com", duration: 300)

    #expect(result.outcome == .notBlocked)
    #expect(result.allowedDomains == ["example.com", "www.example.com"])
    #expect(result.mutations.isEmpty)
    #expect(manager.applyDomainUnblockCallCount == 0)
  }

  @Test("One server's ALLOW for this client is sufficient", arguments: OtherServerEvidence.allCases)
  func allowOnOneServerIsEnough(otherEvidence: OtherServerEvidence) async throws {
    let (manager, _, workflow) = makeWorkflow()
    let first = try #require(manager.servers.first?.id)
    let second = try #require(manager.servers.last?.id)
    manager.getDomainQueryHistoryStub["example.com"]?[first] = .success(history(.permitted))
    switch otherEvidence {
    case .noHistory:
      break
    case .failed:
      manager.getDomainQueryHistoryStub["example.com"]?[second] = .failure(.network("offline"))
    case .incomplete:
      manager.getDomainQueryHistoryStub["example.com"]?[second] = .success(
        DomainQueryHistory(entries: [], isComplete: false))
    case .missing:
      manager.getDomainQueryHistoryStub["example.com"]?[second] = nil
    }

    let result = await workflow.unblock(domain: "example.com", duration: 60)

    #expect(result.allowedDomains == ["example.com"])
    #expect(manager.applyDomainUnblockArgs.map(\.domain) == ["www.example.com"])
    #expect(result.mutations["example.com"] == nil)
    #expect(try result.mutations["www.example.com"]?[first]?.get() == .added)
  }

  @Test func anotherClientsAllowDoesNotSkipUnblocking() async throws {
    let (manager, _, workflow) = makeWorkflow()
    let first = try #require(manager.servers.first?.id)
    let otherClientEntry = DomainQueryEntry(
      domain: "example.com", timestamp: now.addingTimeInterval(-10), queryType: "A",
      clientIP: "192.168.1.99", handling: .permitted, status: "CACHE", reply: "IP")
    manager.getDomainQueryHistoryStub["example.com"]?[first] = .success(
      DomainQueryHistory(entries: [otherClientEntry], isComplete: true))

    let result = await workflow.unblock(domain: "example.com", duration: 60)

    #expect(result.allowedDomains.isEmpty)
    #expect(result.outcome == .processed)
    #expect(manager.applyDomainUnblockCallCount == 2)
  }

  @Test func latestPermittedEntrySupersedesOlderBlock() async throws {
    let (manager, _, workflow) = makeWorkflow()
    for domain in ["example.com", "www.example.com"] {
      let older = history(.ruleBlocked, domain: domain).entries
      let latest = DomainQueryEntry(
        domain: domain, timestamp: now.addingTimeInterval(-1), queryType: "A", clientIP: clientIP,
        handling: .permitted, status: "FORWARDED", reply: nil)
      for id in manager.servers.map(\.id) {
        manager.getDomainQueryHistoryStub[domain]?[id] = .success(
          DomainQueryHistory(entries: older + [latest], isComplete: true))
        manager.applyDomainUnblockStub[id] = .success(.alreadyPresent(enabled: true))
      }
    }

    let result = await workflow.unblock(domain: "example.com", duration: 60)
    #expect(result.outcome == .notBlocked)
    #expect(manager.applyDomainUnblockCallCount == 0)
  }

  @Test func failedHistoryDoesNotPreventNormalUnblocking() async throws {
    let (manager, _, workflow) = makeWorkflow()
    let id = try #require(manager.servers.first?.id)
    manager.getDomainQueryHistoryStub["example.com"]?[id] = .success(history(.ruleBlocked))
    manager.getDomainQueryHistoryStub["www.example.com"]?[id] = .failure(.unauthorized)
    manager.applyDomainUnblockHandler = { _, _, _ in
      [id: .success(.added)]
    }

    let result = await workflow.unblock(domain: "www.example.com", duration: 60)
    #expect(result.outcome == .processed)
    #expect(manager.applyDomainUnblockCallCount == 2)
    #expect(result.checks["www.example.com"]?[id] == .failure(.unauthorized))
  }

  @Test func partialWritesPreserveEveryServerResult() async throws {
    let (manager, _, workflow) = makeWorkflow()
    let first = try #require(manager.servers.first?.id)
    let second = try #require(manager.servers.last?.id)
    manager.getDomainQueryHistoryStub["example.com"]?[first] = .success(history(.ruleBlocked))
    manager.applyDomainUnblockHandler = { domain, _, _ in
      domain == "example.com"
        ? [first: .success(.added), second: .failure(.network("offline"))]
        : [first: .success(.alreadyPresent(enabled: true)), second: .success(.alreadyPresent(enabled: true))]
    }

    let result = await workflow.unblock(domain: "example.com", duration: 60)
    #expect(result.outcome == .processed)
    #expect(try result.mutations["example.com"]?[first]?.get() == .added)
    #expect(result.mutations["example.com"]?[second] == .failure(.network("offline")))
  }

  @Test(arguments: [DomainUnblockOutcome.renewed, .promoted, .alreadyPresent(enabled: false)])
  func existingRowsAreProcessedWithoutBlockEvidence(outcome: DomainUnblockOutcome) async throws {
    let (manager, _, workflow) = makeWorkflow()
    let id = try #require(manager.servers.first?.id)
    manager.applyDomainUnblockStub[id] = .success(outcome)

    let result = await workflow.unblock(domain: "example.com", duration: outcome == .promoted ? nil : 60)
    #expect(result.outcome == .processed)
    #expect(manager.applyDomainUnblockCallCount == 2)
    #expect(try result.mutations["example.com"]?[id]?.get() == outcome)
  }

  @Test func errorsAndIncompleteEvidenceStillUnblockNormally() async throws {
    let (manager, _, workflow) = makeWorkflow()
    let id = try #require(manager.servers.first?.id)
    manager.getDomainQueryHistoryStub["example.com"]?[id] = .success(history(.upstreamBlocked))
    manager.getDomainQueryHistoryStub["www.example.com"]?[id] = .success(
      DomainQueryHistory(entries: [], isComplete: false))
    #expect(await workflow.unblock(domain: "example.com", duration: 60).outcome == .processed)

    manager.getDomainQueryHistoryStub["www.example.com"]?[id] = .failure(.unauthorized)
    let failed = await workflow.unblock(domain: "example.com", duration: 60)
    #expect(failed.outcome == .processed)
    #expect(failed.checks["www.example.com"]?[id] == .failure(.unauthorized))
  }

  @Test func failedWritesWithoutRealOutcomeAreUnavailable() async throws {
    let (manager, _, workflow) = makeWorkflow()
    let id = try #require(manager.servers.first?.id)
    manager.getDomainQueryHistoryStub["example.com"]?[id] = .success(history(.ruleBlocked))
    for server in manager.servers {
      manager.applyDomainUnblockStub[server.id] = .failure(.network("write failed"))
    }
    let result = await workflow.unblock(domain: "example.com", duration: 60)
    #expect(result.outcome == .unavailable)
    #expect(result.mutations["example.com"]?[id] == .failure(.network("write failed")))
  }

  @Test func missingManagerReadResultsUnblockNormally() async {
    let (manager, _, workflow) = makeWorkflow()
    manager.getDomainQueryHistoryStub = [:]
    #expect(await workflow.unblock(domain: "example.com", duration: 60).outcome == .processed)
    #expect(manager.applyDomainUnblockCallCount == 2)
  }

  @Test func missingClientIPSkipsReadAndUnblocksNormally() async {
    let (manager, resolver, workflow) = makeWorkflow()
    resolver.stubbedIP = nil
    let result = await workflow.unblock(domain: "example.com", duration: 60)
    #expect(result.outcome == .processed)
    #expect(manager.getDomainQueryHistoryCallCount == 0)
    #expect(manager.applyDomainUnblockCallCount == 2)
    #expect(result.checks.isEmpty)
  }

  @Test func invalidHostnameAndNoServersMakeNoRequests() async {
    let (manager, _, workflow) = makeWorkflow()
    let invalid = await workflow.unblock(domain: "example.com/path", duration: 60)
    #expect(invalid.outcome == .failed(.invalidDomain("example.com/path")))
    #expect(invalid.checks.isEmpty && invalid.mutations.isEmpty)
    manager.servers = []
    #expect(await workflow.unblock(domain: "example.com", duration: 60).outcome == .noServers)
    #expect(manager.getDomainQueryHistoryCallCount == 0)
    #expect(manager.applyDomainUnblockCallCount == 0)
  }

  @Test func clientScopeStaysCapturedAndEachMutationUsesCurrentServers() async throws {
    let (manager, resolver, workflow) = makeWorkflow()
    let originalIDs = Set(manager.servers.map(\.id))
    for domain in ["example.com", "www.example.com"] {
      for id in originalIDs {
        manager.getDomainQueryHistoryStub[domain]?[id] = .success(history(.ruleBlocked, domain: domain))
      }
    }
    let removed = try #require(manager.servers.first?.id)
    manager.displayLabelStub[removed] = "Captured server"
    var resume: CheckedContinuation<Void, Never>?
    manager.getDomainQueryHistoryGate = { await withCheckedContinuation { resume = $0 } }
    let task = Task { await workflow.unblock(domain: "example.com", duration: 60) }
    await waitUntil { resume != nil }
    resolver.stubbedIP = "192.168.1.99"
    manager.servers.removeAll { $0.id == removed }
    let added = ServerConfig(label: "New", url: "http://new.local", version: .v6)
    manager.servers.append(added)
    manager.displayLabelStub[removed] = "Changed server"
    manager.applyDomainUnblockStub[added.id] = .failure(.network("New server offline"))
    resume?.resume()

    let result = await task.value
    #expect(result.clientIP == clientIP)
    #expect(result.serverLabels[removed] == "Captured server")
    #expect(result.serverLabels[added.id] == "New")
    #expect(manager.getDomainQueryHistoryLastClientIP == clientIP)
    #expect(manager.getDomainQueryHistoryLastServerIDs == originalIDs)
    let currentIDs = Set(manager.servers.map(\.id))
    #expect(manager.applyDomainUnblockArgs.allSatisfy { $0.serverIDs == currentIDs })
    #expect(result.allowedDomains.isEmpty)
    #expect(result.mutations["example.com"]?[removed] == nil)
    #expect(result.mutations["example.com"]?[added.id] == .failure(.network("New server offline")))
  }

  @Test func apexAndWWWTriggersShareGuardThroughReadAndWrites() async {
    let (manager, resolver, workflow) = makeWorkflow()
    var readResume: CheckedContinuation<Void, Never>?
    var writeResume: CheckedContinuation<Void, Never>?
    manager.getDomainQueryHistoryGate = { await withCheckedContinuation { readResume = $0 } }
    manager.applyDomainUnblockHandler = { domain, _, serverIDs in
      if domain == "example.com" { await withCheckedContinuation { writeResume = $0 } }
      return Dictionary(uniqueKeysWithValues: serverIDs.map { ($0, .success(.alreadyPresent(enabled: true))) })
    }
    let first = Task { await workflow.unblock(domain: "www.example.com", duration: 60) }
    await waitUntil { readResume != nil }
    resolver.stubbedIP = nil
    #expect(await workflow.unblock(domain: "EXAMPLE.COM.", duration: 60).outcome == .inProgress)
    resolver.stubbedIP = clientIP
    #expect(manager.getDomainQueryHistoryCallCount == 1)
    readResume?.resume()
    await waitUntil { writeResume != nil }
    #expect(await workflow.unblock(domain: "example.com", duration: nil).outcome == .inProgress)
    #expect(manager.applyDomainUnblockCallCount == 1)
    writeResume?.resume()
    #expect(await first.value.outcome == .processed)

    manager.applyDomainUnblockHandler = nil
    #expect(await workflow.unblock(domain: "example.com", duration: 60).outcome == .processed)
    #expect(manager.getDomainQueryHistoryCallCount == 2)
  }

  @Test func cancellationAfterReadPreventsAnyWrite() async throws {
    let (manager, _, workflow) = makeWorkflow()
    let id = try #require(manager.servers.first?.id)
    manager.getDomainQueryHistoryStub["example.com"]?[id] = .success(history(.ruleBlocked))
    var resume: CheckedContinuation<Void, Never>?
    manager.getDomainQueryHistoryGate = { await withCheckedContinuation { resume = $0 } }
    let task = Task { await workflow.unblock(domain: "example.com", duration: 60) }
    await waitUntil { resume != nil }
    task.cancel()
    resume?.resume()
    let result = await task.value
    #expect(result.outcome == .cancelled)
    #expect(manager.applyDomainUnblockCallCount == 0)
    #expect(try result.checks["example.com"]?[id]?.get() == .blocked)
    #expect(result.mutations.isEmpty)
  }

  @Test func cancellationBeforeStartPreventsHistoryReads() async {
    let (manager, _, workflow) = makeWorkflow()
    let task = Task { await workflow.unblock(domain: "example.com", duration: 60) }
    task.cancel()
    #expect(await task.value.outcome == .cancelled)
    #expect(manager.getDomainQueryHistoryCallCount == 0)
    #expect(manager.applyDomainUnblockCallCount == 0)
  }

  @Test func cancellationAfterCompletedWriteKeepsOutcomeAndStopsNextCandidate() async throws {
    let (manager, _, workflow) = makeWorkflow()
    let id = try #require(manager.servers.first?.id)
    var resume: CheckedContinuation<Void, Never>?
    manager.applyDomainUnblockHandler = { _, _, _ in
      await withCheckedContinuation { resume = $0 }
      return [id: .success(.renewed)]
    }
    let task = Task { await workflow.unblock(domain: "example.com", duration: 60) }
    await waitUntil { resume != nil }
    task.cancel()
    resume?.resume()
    let result = await task.value
    #expect(result.outcome == .processed)
    #expect(try result.mutations["example.com"]?[id]?.get() == .renewed)
    #expect(result.mutations["www.example.com"] == nil)
    #expect(manager.applyDomainUnblockCallCount == 1)
  }

  @Test func managerInProgressDoesNotCountAsRealRowOutcome() async throws {
    let (manager, _, workflow) = makeWorkflow()
    for server in manager.servers {
      manager.applyDomainUnblockStub[server.id] = .success(.inProgress)
    }
    #expect(await workflow.unblock(domain: "example.com", duration: 60).outcome != .processed)
  }

  private func makeWorkflow() -> (MockPiholeServerManager, MockLocalIPAddressResolver, LiveBrowserDomainUnblocker) {
    let manager = MockPiholeServerManager()
    manager.servers = [
      ServerConfig(label: "Primary", url: "http://primary.local", version: .v6),
      ServerConfig(label: "Secondary", url: "http://secondary.local", version: .v5)
    ]
    for domain in ["example.com", "www.example.com"] {
      manager.getDomainQueryHistoryStub[domain] = Dictionary(
        uniqueKeysWithValues: manager.servers.map {
          ($0.id, .success(DomainQueryHistory(entries: [], isComplete: true)))
        })
    }
    manager.applyDomainUnblockStub = Dictionary(uniqueKeysWithValues: manager.servers.map { ($0.id, .success(.added)) })
    let resolver = MockLocalIPAddressResolver()
    resolver.stubbedIP = clientIP
    let workflow = LiveBrowserDomainUnblocker(manager: manager, networkInterface: resolver, now: { now })
    return (manager, resolver, workflow)
  }

  private func history(_ handling: DomainQueryHandling, domain: String = "example.com") -> DomainQueryHistory {
    DomainQueryHistory(
      entries: [
        DomainQueryEntry(
          domain: domain, timestamp: now.addingTimeInterval(-10), queryType: "A", clientIP: clientIP,
          handling: handling, status: String(describing: handling), reply: nil)
      ], isComplete: true)
  }
}
