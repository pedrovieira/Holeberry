import XCTest

@testable import Holeberry

@MainActor
final class PiHoleScannerTests: XCTestCase {
  // MARK: - DiscoveredInstance model

  func testDiscoveredInstance_idIsAddr() {
    let instance = PiholeDiscoveryService.DiscoveredInstance(addr: "192.168.1.10")
    XCTAssertEqual(instance.id, "192.168.1.10")
  }

  func testDiscoveredInstance_adminURL() {
    let instance = PiholeDiscoveryService.DiscoveredInstance(addr: "192.168.1.10")
    XCTAssertEqual(instance.adminURL.absoluteString, "http://192.168.1.10/admin")
  }

  // MARK: - Deduplication (IP containment)

  func testFilter_exactIPMatch_removesDuplicate() {
    let discovered = [
      PiholeDiscoveryService.DiscoveredInstance(addr: "192.168.1.10")
    ]
    let connected = [
      ServerConfig(label: nil, url: "http://192.168.1.10", version: .v6)
    ]
    let result = filterDiscovered(discovered, against: connected)
    XCTAssertTrue(result.isEmpty)
  }

  func testFilter_ipInURL_removesDuplicate() {
    let discovered = [
      PiholeDiscoveryService.DiscoveredInstance(addr: "192.168.1.10")
    ]
    let connected = [
      ServerConfig(label: nil, url: "http://192.168.1.10:8080/admin", version: .v6)
    ]
    let result = filterDiscovered(discovered, against: connected)
    XCTAssertTrue(result.isEmpty)
  }

  func testFilter_customDomain_keepsInstance() {
    let discovered = [
      PiholeDiscoveryService.DiscoveredInstance(addr: "192.168.1.10")
    ]
    let connected = [
      ServerConfig(label: nil, url: "https://pihole.server.com", version: .v6)
    ]
    let result = filterDiscovered(discovered, against: connected)
    XCTAssertEqual(result.count, 1)
    XCTAssertEqual(result[0].addr, "192.168.1.10")
  }

  func testFilter_partialIPMatch_keepsInstance() {
    // "192.168.1.1" should NOT match "192.168.1.10"
    let discovered = [
      PiholeDiscoveryService.DiscoveredInstance(addr: "192.168.1.1")
    ]
    let connected = [
      ServerConfig(label: nil, url: "http://192.168.1.10", version: .v6)
    ]
    let result = filterDiscovered(discovered, against: connected)
    XCTAssertEqual(result.count, 1)
  }

  func testFilter_multipleInstances_mixedDedup() {
    let discovered = [
      PiholeDiscoveryService.DiscoveredInstance(addr: "192.168.1.10"),
      PiholeDiscoveryService.DiscoveredInstance(addr: "192.168.1.20"),
      PiholeDiscoveryService.DiscoveredInstance(addr: "192.168.1.30")
    ]
    let connected = [
      ServerConfig(label: nil, url: "http://192.168.1.20:80", version: .v6)
    ]
    let result = filterDiscovered(discovered, against: connected)
    XCTAssertEqual(result.count, 2)
    XCTAssertEqual(result[0].addr, "192.168.1.10")
    XCTAssertEqual(result[1].addr, "192.168.1.30")
  }

  // MARK: - Sorting

  func testDiscoveredInstance_sorting() {
    let unsorted = [
      PiholeDiscoveryService.DiscoveredInstance(addr: "192.168.1.30"),
      PiholeDiscoveryService.DiscoveredInstance(addr: "192.168.1.2"),
      PiholeDiscoveryService.DiscoveredInstance(addr: "192.168.1.10")
    ]
    let sorted = unsorted.sorted {
      $0.addr.localizedStandardCompare($1.addr) == .orderedAscending
    }
    XCTAssertEqual(sorted[0].addr, "192.168.1.2")
    XCTAssertEqual(sorted[1].addr, "192.168.1.10")
    XCTAssertEqual(sorted[2].addr, "192.168.1.30")
  }
}

/// Pure deduplication function.
private func filterDiscovered(
  _ discovered: [PiholeDiscoveryService.DiscoveredInstance],
  against servers: [ServerConfig]
) -> [PiholeDiscoveryService.DiscoveredInstance] {
  discovered.filter { instance in
    !servers.contains { server in
      // Match the IP as the host portion of the URL, avoiding substring false positives.
      guard let components = URLComponents(string: server.url),
        let host = components.host
      else {
        return server.url.contains(instance.addr)
      }
      return host == instance.addr
    }
  }
}
