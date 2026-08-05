import Foundation

@testable import HoleberryCore

/// Configurable mock implementing `LocalIPAddressProviding` with a stubbed IP address.
final class MockLocalIPAddressResolver: LocalIPAddressProviding, @unchecked Sendable {
  var stubbedIP: String?

  func localIPAddress() -> String? {
    stubbedIP
  }
}
