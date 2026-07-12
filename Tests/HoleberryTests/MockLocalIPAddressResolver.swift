import Foundation

@testable import Holeberry

/// Configurable mock implementing `LocalIPAddressProviding` with a stubbed IP address.
final class MockLocalIPAddressResolver: LocalIPAddressProviding {
  var stubbedIP: String?

  func localIPAddress() -> String? {
    stubbedIP
  }
}
