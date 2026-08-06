import Foundation

@testable import HoleberryCore

/// Configurable mock implementing `EffectiveDNSServerProviding` with a stubbed server list.
final class MockEffectiveDNSServerResolver: EffectiveDNSServerProviding, @unchecked Sendable {
  var stubbedServers: [String] = []

  func effectiveDNSServers() -> [String] {
    stubbedServers
  }
}
