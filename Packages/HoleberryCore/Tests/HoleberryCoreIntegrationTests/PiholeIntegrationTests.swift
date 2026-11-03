import Defaults
import Foundation
import Testing

@testable import HoleberryCore

/// Opt-in end-to-end tests against real Pi-hole v5, v6 and password-less v6.
///
/// Every scenario declares its own prerequisites with the Pi-hole CLI, acts
/// through the production service, and checks the result with an independent
/// oracle where possible: the Pi-hole CLI list or a DNS query.
@Suite(
  .serialized,
  .enabled(if: IntegrationEnvironment.isEnabled)
)
@MainActor
struct PiholeIntegrationTests {
  private let detector = PiholeVersionDetector()
  private let regexFixture = #"(^|\.)regex\.holeberry\.test$"#

  // MARK: - Detection and authentication

  @Test("detection", arguments: IntegrationTarget.allCases)
  func detection(_ target: IntegrationTarget) async throws {
    try await assertDetection(target)
  }

  private func assertDetection(_ target: IntegrationTarget) async throws {
    try await withContext(target) { context in
      let detected = try await detector.detect(baseURL: context.baseURL, session: context.session)
      #expect(detected == target.version)

      try await context.service.login()
      let blocking = try await context.service.checkStatus()
      #expect(blocking == .enabled)

      // Prerequisite: at least one query in the log so the summary has data.
      _ = try await context.dig("example.com")
      try await pollUntil(description: "query summary reports traffic") {
        let summary = try await context.service.getQuerySummary()
        return summary.totalQueries > 0
      }

      if target.isPasswordless {
        let passwordless = await context.service.isPasswordless
        #expect(passwordless == true, "an empty v6 password must be treated as password-less")
      } else {
        // A wrong credential must fail an authenticated mutation, and it must
        // not leave an entry behind.
        let domain = "wrong-credential-\(UUID().uuidString.lowercased().prefix(8)).holeberry.test"
        try await withWrongCredentialService(for: context) { wrongService in
          do {
            _ = try await wrongService.addDomain(domain, to: .deny, comment: nil)
            Issue.record("a wrong credential must not mutate the deny list")
          } catch {
            // Expected on both versions, with different error types.
          }
        }

        let created = try await context.service.getDomain(domain, from: .deny)
        #expect(created == nil)
      }
    }
  }

  @Test("logout", arguments: [IntegrationTarget.v6, .v6Open])
  func logout(_ target: IntegrationTarget) async throws {
    try await withContext(target) { context in
      let before = try await context.cli.activeAPISessionIDs(context.container)

      try await context.service.login()
      let afterLogin = try await context.cli.activeAPISessionIDs(context.container)
      let created = afterLogin.subtracting(before)

      if target.isPasswordless {
        #expect(afterLogin == before, "password-less login must not create an API session")
      } else {
        try #require(created.count == 1, "login must create one observable API session")
      }

      await context.service.logout()

      let afterLogout = try await context.cli.activeAPISessionIDs(context.container)
      #expect(created.isDisjoint(with: afterLogout), "logout must revoke the app's API session")
      #expect(afterLogout == before, "logout must preserve pre-existing sessions")
    }
  }

  @Test("revoked v6 session recovers automatically")
  func revokedSessionRecovers() async throws {
    try await withContext(.v6) { context in
      let before = try await context.cli.activeAPISessionIDs(context.container)
      try await context.service.login()
      let afterLogin = try await context.cli.activeAPISessionIDs(context.container)
      let created = afterLogin.subtracting(before)
      try #require(created.count == 1, "login must create one observable API session")
      let sessionID = try #require(created.first)

      let revokeStatus = try await context.cli.revokeAPISession(sessionID, on: context.container)
      try #require(revokeStatus == "204", "the independent DELETE must revoke the app session")
      let afterRevocation = try await context.cli.activeAPISessionIDs(context.container)
      try #require(afterRevocation == before, "only the app's session must be revoked")

      // Keep using the same service: its cached SID is now invalid. No explicit
      // login here, so this request must recover through the production 401 path.
      let status = try await context.service.checkStatus()
      #expect(status == .enabled)

      let afterRecovery = try await context.cli.activeAPISessionIDs(context.container)
      #expect(before.isSubset(of: afterRecovery), "recovery must preserve pre-existing sessions")
      // FTL may reuse the revoked session's numeric slot, so a replacement does
      // not have to have a different ID. Its absence above proves revocation.
      #expect(afterRecovery.subtracting(before).count == 1, "recovery must create one replacement session")

      _ = try await context.service.getQuerySummary()
      let afterNextRequest = try await context.cli.activeAPISessionIDs(context.container)
      #expect(afterNextRequest == afterRecovery, "subsequent requests must reuse the replacement session")
    }
  }

  // MARK: - Domain lists

  @Test("domains", arguments: IntegrationTarget.allCases)
  func domains(_ target: IntegrationTarget) async throws {
    try await assertDomains(target)
  }

  private func assertDomains(_ target: IntegrationTarget) async throws {
    try await withContext(target) { context in
      // Simulate a prior run that seeded only the first allow entry.
      if try await context.service.getDomain("allowed.holeberry.test", from: .allow) == nil {
        try await seedAllow(["allowed.holeberry.test"], context: context)
      }
      try await context.service.deleteDomain("xn--bcher-kva.holeberry.test", from: .allow)
      try await seedDomainFixtures(context)

      let allow = try await context.service.getDomains(from: .allow)
      #expect(allow.contains { PiholeDomain.identity($0.domain) == "allowed.holeberry.test" })
      #expect(allow.contains { PiholeDomain.identity($0.domain) == "xn--bcher-kva.holeberry.test" })

      let deny = try await context.service.getDomains(from: .deny)
      #expect(deny.contains { PiholeDomain.identity($0.domain) == "denied.holeberry.test" })
      #expect(!deny.contains { $0.domain == regexFixture })

      // Independent oracle: the CLI sees the same seeded entries.
      let allowList = try await context.cliList(.allow)
      #expect(allowList.contains("allowed.holeberry.test"))
      #expect(allowList.contains("xn--bcher-kva.holeberry.test"))
      let denyList = try await context.cliList(.deny)
      #expect(denyList.contains("denied.holeberry.test"))
      #expect(!denyList.contains(regexFixture))

      let domain = "added-\(UUID().uuidString.lowercased().prefix(8)).holeberry.test"
      context.registerOwnedDomain(domain, in: .allow)

      let firstAdd = try await context.service.addDomain(
        domain, to: .allow, comment: "holeberry e2e"
      )
      #expect(firstAdd == .added)

      let cliAfterAdd = try await context.cliList(.allow)
      #expect(cliAfterAdd.contains(domain))

      let added = try await context.service.getDomain(domain, from: .allow)
      #expect(added?.comment == "holeberry e2e")

      let secondAdd = try await context.service.addDomain(
        domain, to: .allow, comment: "ignored"
      )
      #expect(secondAdd == .alreadyPresent)

      let preserved = try await context.service.getDomain(domain, from: .allow)
      #expect(preserved?.comment == "holeberry e2e")

      try await context.service.deleteDomain(domain, from: .allow)
      let removed = try await context.service.getDomain(domain, from: .allow)
      #expect(removed == nil)

      let cliAfterDelete = try await context.cliList(.allow)
      #expect(!cliAfterDelete.contains(domain))

      // Deleting an already missing entry is a no-op on both versions.
      try await context.service.deleteDomain(domain, from: .allow)
      let stillRemoved = try await context.service.getDomain(domain, from: .allow)
      #expect(stillRemoved == nil)
    }
  }

  // MARK: - Blocking controls

  @Test("blocking", arguments: IntegrationTarget.allCases)
  func blocking(_ target: IntegrationTarget) async throws {
    try await assertBlocking(target)
  }

  private func assertBlocking(_ target: IntegrationTarget) async throws {
    try await withContext(target) { context in
      context.registerBlockingRestoration(enabled: true)

      // DNS oracle: a CLI-seeded deny is blocked while blocking is enabled.
      let initiallyBlocked = try await seedDenyDomain(context, prefix: "blocked-enabled")
      try await waitForBlocked(initiallyBlocked, context: context)

      // Seed this one before disabling, so it was never queried while blocked.
      let whileDisabled = try await seedDenyDomain(context, prefix: "blocked-disabled")
      try await context.service.setBlocking(enabled: false, duration: nil)
      try await waitForDisabled(context)
      try await waitForNotBlocked(whileDisabled, context: context)

      try await context.service.setBlocking(enabled: true, duration: nil)
      try await waitForEnabled(context)
      let afterEnable = try await seedDenyDomain(context, prefix: "blocked-reenabled")
      try await waitForBlocked(afterEnable, context: context)

      // A timed disable must re-enable itself. Ten seconds leaves room for the
      // seed and DNS query while blocking is off.
      let timed = try await seedDenyDomain(context, prefix: "blocked-timed")
      try await context.service.setBlocking(enabled: false, duration: 10)
      try await waitForDisabled(context)
      try await waitForNotBlocked(timed, context: context)

      try await pollUntil(timeout: .seconds(20), description: "blocking re-enabled by timer") {
        let status = try await context.service.checkStatus()
        return status == .enabled
      }
      let afterTimer = try await seedDenyDomain(context, prefix: "blocked-after-timer")
      try await waitForBlocked(afterTimer, context: context)
    }
  }

  // MARK: - Managed temporary unblocks

  @Test("managed unblock", arguments: IntegrationTarget.allCases)
  func managedUnblock(_ target: IntegrationTarget) async throws {
    try await assertManagedUnblock(target)
  }

  private func assertManagedUnblock(_ target: IntegrationTarget) async throws {
    try await withContext(target) { context in
      // Compose gives this domain a local answer, so neither an empty answer
      // nor an upstream DNS failure can masquerade as a successful unblock.
      let domain = "unblock.holeberry.test"
      let existingAllowance = try await context.service.getDomain(domain, from: .allow)
      try #require(existingAllowance == nil, "the DNS fixture must not already be allowed")
      context.registerOwnedDomain(domain, in: .allow)
      context.registerOwnedDomain(domain, in: .deny)
      try await seedDeny([domain], context: context)
      try await waitForBlocked(domain, context: context)

      let outcome = try await context.service.unblockDomain(domain, duration: 20)
      #expect(outcome == .added)

      try await pollUntil(timeout: .seconds(10), description: "temporary unblock returns the local DNS answer") {
        let answer = try await context.dig(domain)
        return answer.trimmingCharacters(in: .whitespacesAndNewlines) == "192.0.2.123"
      }

      let entry = try await context.service.getDomain(domain, from: .allow)
      #expect(entry?.comment?.hasPrefix("via holeberryapp.com / ") == true)

      let records = tempUnblocks(context)
      #expect(records.contains { PiholeDomain.identity($0.domain) == PiholeDomain.identity(domain) })

      // Independent oracle: the CLI list agrees, including the v6 comment.
      let allowList = try await context.cliList(.allow)
      #expect(allowList.contains(domain))
      if target.version == .v6 {
        #expect(allowList.contains("via holeberryapp.com / "))
      }

      try await pollUntil(timeout: .seconds(30), description: "temporary allow removed") {
        let current = try await context.service.getDomain(domain, from: .allow)
        return current == nil
      }
      try await pollUntil(
        timeout: .seconds(10), description: "temporary allow gone from the CLI list"
      ) {
        let list = try await context.cliList(.allow)
        return !list.contains(domain)
      }
      // The server entry can disappear slightly before the local record is cleared.
      try await pollUntil(timeout: .seconds(10), description: "temporary unblock record cleared") {
        tempUnblocks(context).isEmpty
      }
      try await waitForBlocked(domain, context: context)

      // A pre-existing allowance is not owned by the app: it must survive and
      // keep its original comment.
      try await seedDomainFixtures(context)
      let existing = try await context.service.getDomain("allowed.holeberry.test", from: .allow)
      let existingComment = existing?.comment
      #expect(existing != nil)

      let existingOutcome = try await context.service.unblockDomain(
        "allowed.holeberry.test", duration: 2
      )
      if case .alreadyPresent = existingOutcome {
        // Expected: the app did not create this entry.
      } else {
        Issue.record("expected .alreadyPresent for a pre-existing allowance, got \(existingOutcome)")
      }

      try await Task.sleep(for: .seconds(3))
      let after = try await context.service.getDomain("allowed.holeberry.test", from: .allow)
      #expect(after != nil)
      #expect(after?.comment == existingComment)
      #expect(tempUnblocks(context).isEmpty)

      let finalList = try await context.cliList(.allow)
      #expect(finalList.contains("allowed.holeberry.test"))
    }
  }

  // MARK: - Query log and gravity

  @Test("query and gravity", arguments: IntegrationTarget.allCases)
  func queryAndGravity(_ target: IntegrationTarget) async throws {
    try await assertQueryAndGravity(target)
  }

  private func assertQueryAndGravity(_ target: IntegrationTarget) async throws {
    try await withContext(target) { context in
      // Prerequisite: the fixture adlist must already block this domain.
      let blockedAnswer = try await context.dig("gravity.holeberry.test")
      #expect(
        blockedAnswer.contains("0.0.0.0"),
        "the fixture adlist must be active; run just integration-up from the repository root"
      )

      // Prerequisite: a non-gravity query, so the summary has both counts.
      _ = try await context.dig("example.com")

      try await pollUntil(timeout: .seconds(30), description: "summary reports the queries") {
        let summary = try await context.service.getQuerySummary()
        return summary.totalQueries > 0 && summary.totalBlocked > 0
      }

      // A wide window keeps the v5 string-timestamp parsing independent of the
      // host time zone; the assertions are about the domain, not the interval.
      let interval = DateInterval(
        start: Date(timeIntervalSinceNow: -86_400),
        end: Date(timeIntervalSinceNow: 3_600)
      )

      try await pollUntil(timeout: .seconds(30), description: "gravity domain in recent blocked") {
        let entries = try await context.service.getRecentBlocked(
          forClientIp: nil, interval: interval
        )
        return entries.contains {
          $0.domain.caseInsensitiveCompare("gravity.holeberry.test") == .orderedSame
        }
      }

      // v5's API ignores the client filter and the production service does not
      // post-filter, so matching and excluded client checks only run on v6.
      if target.version == .v6 {
        // dig queries the container's loopback DNS server, so its client is 127.0.0.1.
        try await pollUntil(description: "gravity domain for the matching client") {
          let matching = try await context.service.getRecentBlocked(
            forClientIp: "127.0.0.1", interval: interval
          )
          return matching.contains {
            $0.domain.caseInsensitiveCompare("gravity.holeberry.test") == .orderedSame
              && $0.fromClientIp == "127.0.0.1"
          }
        }

        let excluded = try await context.service.getRecentBlocked(
          forClientIp: "192.0.2.254", interval: interval
        )
        #expect(excluded.isEmpty)
      }

      switch target.version {
      case .v5:
        do {
          try await context.service.updateGravity()
          Issue.record("v5 must report API gravity updates as unsupported")
        } catch let error as PiholeError {
          guard case .unsupported = error else {
            Issue.record("unexpected v5 gravity error: \(error)")
            return
          }
        }
      case .v6:
        try await assertGravityRebuild(context)
      }
    }
  }

  // MARK: - Prerequisites and helpers

  /// A no-op API update must fail even when DNS still has a cached blocked answer.
  private func assertGravityRebuild(_ context: IntegrationContext) async throws {
    let fixtureExists = """
      SELECT EXISTS(SELECT 1 FROM gravity WHERE domain = 'gravity.holeberry.test');
      """
    let before = try await context.cli.run(
      context.container, "pihole-FTL", "sqlite3", "/etc/pihole/gravity.db", fixtureExists
    )
    try #require(before.trimmingCharacters(in: .whitespacesAndNewlines) == "1")

    do {
      // Remove only the compiled fixture row. Its source adlist stays unchanged,
      // so a real gravity rebuild must import it again.
      let removed = try await context.cli.run(
        context.container, "pihole-FTL", "sqlite3", "/etc/pihole/gravity.db",
        "DELETE FROM gravity WHERE domain = 'gravity.holeberry.test'; \(fixtureExists)"
      )
      try #require(removed.trimmingCharacters(in: .whitespacesAndNewlines) == "0")

      try await context.service.updateGravity()

      let rebuilt = try await context.cli.run(
        context.container, "pihole-FTL", "sqlite3", "/etc/pihole/gravity.db", fixtureExists
      )
      try #require(
        rebuilt.trimmingCharacters(in: .whitespacesAndNewlines) == "1",
        "the API gravity update must re-import the fixture from its adlist"
      )
      try await waitForBlocked("gravity.holeberry.test", context: context)
    } catch {
      let operationError = error
      // Repair the shared fixture if the API update or its assertion failed.
      do {
        try await context.cli.run(context.container, "pihole", "-g")
      } catch {
        throw IntegrationOperationFailure(operation: operationError, cleanup: error)
      }
      throw operationError
    }
  }

  /// Seeds the shared exact and regex entries through the Pi-hole CLI.
  private func seedDomainFixtures(_ context: IntegrationContext) async throws {
    let allow = ["allowed.holeberry.test", "xn--bcher-kva.holeberry.test"]
    for domain in allow {
      if try await context.service.getDomain(domain, from: .allow) == nil {
        try await seedAllow([domain], context: context)
      }
    }

    let deny = ["denied.holeberry.test"]
    let denyExists = try await context.service.getDomain(deny[0], from: .deny) != nil
    if !denyExists {
      try await seedDeny(deny, context: context)
    }

    // Regex entries have no API surface in Holeberry, so the CLI is the only
    // way to seed and verify them.
    _ = try await context.cli.run(
      context.container, "pihole", "--regex", "-q", regexFixture
    )
    let regexList = try await context.cli.run(context.container, "pihole", "--regex", "-l")
    try #require(regexList.contains(regexFixture), "the regex fixture must exist before testing exact lists")
  }

  private func seedAllow(_ domains: [String], context: IntegrationContext) async throws {
    switch context.target {
    case .v5:
      _ = try await context.cli.run(
        context.container, arguments: ["pihole", "-w", "-q"] + domains
      )
    case .v6, .v6Open:
      _ = try await context.cli.run(
        context.container, arguments: ["pihole", "allow", "-q"] + domains
      )
    }
  }

  private func seedDeny(_ domains: [String], context: IntegrationContext) async throws {
    switch context.target {
    case .v5:
      _ = try await context.cli.run(
        context.container, arguments: ["pihole", "-b", "-q"] + domains
      )
    case .v6, .v6Open:
      _ = try await context.cli.run(
        context.container, arguments: ["pihole", "deny", "-q"] + domains
      )
    }
  }

  /// Seeds a unique deny entry and registers it for cleanup.
  private func seedDenyDomain(
    _ context: IntegrationContext,
    prefix: String
  ) async throws -> String {
    let domain = "\(prefix)-\(UUID().uuidString.lowercased().prefix(8)).holeberry.test"
    context.registerOwnedDomain(domain, in: .deny)
    try await seedDeny([domain], context: context)
    return domain
  }

  private func waitForBlocked(_ domain: String, context: IntegrationContext) async throws {
    try await pollUntil(timeout: .seconds(15), description: "\(domain) is blocked") {
      let answer = try await context.dig(domain)
      return answer.contains("0.0.0.0")
    }
  }

  private func waitForNotBlocked(_ domain: String, context: IntegrationContext) async throws {
    try await pollUntil(timeout: .seconds(15), description: "\(domain) is not blocked") {
      let answer = try await context.dig(domain)
      return !answer.contains("0.0.0.0")
    }
  }

  private func waitForDisabled(_ context: IntegrationContext) async throws {
    try await pollUntil(description: "blocking disabled") {
      if case .disabled = try await context.service.checkStatus() {
        return true
      }
      return false
    }
  }

  private func waitForEnabled(_ context: IntegrationContext) async throws {
    try await pollUntil(description: "blocking enabled") {
      let status = try await context.service.checkStatus()
      return status == .enabled
    }
  }

  private func tempUnblocks(_ context: IntegrationContext) -> [TempUnblockRecord] {
    Defaults[.tempUnblocks(for: context.config.id, suite: context.defaults)]
  }

  private func withWrongCredentialService(
    for context: IntegrationContext,
    operation: (any PiholeServiceProviding) async throws -> Void
  ) async throws {
    let suiteName = "com.holeberry.integration.wrong.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
      throw IntegrationContextError.defaultsSuiteUnavailable
    }
    defaults.removePersistentDomain(forName: suiteName)

    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 30
    let session = URLSession(configuration: configuration)
    defer {
      session.invalidateAndCancel()
      defaults.removePersistentDomain(forName: suiteName)
    }
    let config = ServerConfig(url: context.config.url, version: context.version)

    let service = try ConcretePiholeServiceFactory(
      authSessionFactory: ConcreteAuthSessionFactory()
    ).buildService(
      config: config,
      credential: "wrong-credential",
      session: session,
      suite: defaults
    )
    try await operation(service)
  }
}
