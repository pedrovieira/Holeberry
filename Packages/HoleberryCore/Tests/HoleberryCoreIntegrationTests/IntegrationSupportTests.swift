import Foundation
import Testing

@Suite("Integration support")
@MainActor
struct IntegrationSupportTests {
  @Test(
    "Malformed endpoint overrides fail instead of selecting another service",
    arguments: ["", "http://[", "localhost:18086", "/relative", "file:///tmp/pihole", "http:///api"]
  )
  func rejectsMalformedOverride(raw: String) async {
    #expect(throws: IntegrationEnvironmentError.invalidURLOverride(key: "HOLEBERRY_V6_URL", value: raw)) {
      try IntegrationEnvironment.baseURL(for: .v6, environment: ["HOLEBERRY_V6_URL": raw])
    }
  }

  @Test("Each lane uses its own endpoint override", arguments: IntegrationTarget.allCases)
  func endpointOverride(target: IntegrationTarget) throws {
    let url = try IntegrationEnvironment.baseURL(
      for: target,
      environment: [
        "HOLEBERRY_V5_URL": "http://localhost:19085",
        "HOLEBERRY_V6_URL": "https://localhost:19086/api",
        "HOLEBERRY_V6_OPEN_URL": "http://localhost:19087"
      ]
    )
    switch target {
    case .v5:
      #expect(url.absoluteString == "http://localhost:19085")
    case .v6:
      #expect(url.absoluteString == "https://localhost:19086/api")
    case .v6Open:
      #expect(url.absoluteString == "http://localhost:19087")
    }
  }

  @Test("Absent endpoint overrides use the local containers", arguments: IntegrationTarget.allCases)
  func defaultEndpoint(target: IntegrationTarget) throws {
    let url = try IntegrationEnvironment.baseURL(for: target, environment: [:])
    switch target {
    case .v5:
      #expect(url.absoluteString == "http://127.0.0.1:18085")
    case .v6:
      #expect(url.absoluteString == "http://127.0.0.1:18086")
    case .v6Open:
      #expect(url.absoluteString == "http://127.0.0.1:18087")
    }
  }

  @Test("Polling observes a condition that becomes true at the deadline")
  func observesDeadline() async throws {
    let clock = ContinuousClock()
    let readyAt = clock.now.advanced(by: .milliseconds(20))
    try await pollUntil(timeout: .milliseconds(20), interval: .seconds(1), description: "deadline") {
      clock.now >= readyAt
    }
  }

  @Test("Polling times out when the condition stays false")
  func timesOut() async {
    await #expect(throws: PollingError.timedOut("never ready")) {
      try await pollUntil(timeout: .milliseconds(10), description: "never ready") { false }
    }
  }
}
