import Foundation
import Testing

@testable import HoleberryCore

// swiftlint:disable attributes

@MainActor
@Suite("PiholeDiscoveryService — model")
struct PiholeDiscoveryServiceModelTests {
  @Test func idIsAddr() {
    let instance = PiholeDiscoveryService.DiscoveredInstance(addr: "192.168.1.10")
    #expect(instance.id == "192.168.1.10")
  }

  @Test func adminURL() {
    let instance = PiholeDiscoveryService.DiscoveredInstance(addr: "192.168.1.10")
    #expect(instance.adminURL.absoluteString == "http://192.168.1.10/admin")
  }

  @Test("sorted by IP numerically")
  func sorting() {
    let unsorted = [
      PiholeDiscoveryService.DiscoveredInstance(addr: "192.168.1.30"),
      PiholeDiscoveryService.DiscoveredInstance(addr: "192.168.1.2"),
      PiholeDiscoveryService.DiscoveredInstance(addr: "192.168.1.10")
    ]
    let sorted = unsorted.sorted {
      $0.addr.localizedStandardCompare($1.addr) == .orderedAscending
    }
    #expect(sorted[0].addr == "192.168.1.2")
    #expect(sorted[1].addr == "192.168.1.10")
    #expect(sorted[2].addr == "192.168.1.30")
  }
}

// MARK: - Handler helpers

/// Wraps a response closure so it only serves requests for `addr`; requests for
/// other hosts decline (the handler stays in the queue for its own host).
private func handler(
  forAddr addr: String,
  _ body: @escaping (URLRequest) throws -> (Data, HTTPURLResponse)
) -> (URLRequest) throws -> (Data, HTTPURLResponse) {
  { request in
    guard request.url?.host() == addr else { throw MockURLSession.Mismatch.declined }
    return try body(request)
  }
}

/// Builds the handler queue for a full subnet scan: every host in
/// 192.168.1.1...254 gets a host-guarded handler; hosts in `responders` serve
/// their own requests, the rest simulate an unreachable host.
/// Hosts in `twoCallHosts` get a second identical copy of their handler because
/// `checkInstance` retries via `/api/info` when the admin page has no Pi-hole
/// content — those handlers must be path-aware.
private func scanHandlers(
  responders: [Int: (URLRequest) throws -> (Data, HTTPURLResponse)],
  twoCallHosts: Set<Int> = []
) -> [(URLRequest) throws -> (Data, HTTPURLResponse)] {
  (1...254).flatMap { idx -> [(URLRequest) throws -> (Data, HTTPURLResponse)] in
    let addr = "192.168.1.\(idx)"
    let handler = handler(forAddr: addr) { request in
      if let respond = responders[idx] {
        return try respond(request)
      }
      throw URLError(.notConnectedToInternet)
    }
    return twoCallHosts.contains(idx) ? [handler, handler] : [handler]
  }
}

private func unreachableHandlers() -> [(URLRequest) throws -> (Data, HTTPURLResponse)] {
  scanHandlers(responders: [:])
}

// MARK: - Scanning

@MainActor
@Suite("PiholeDiscoveryService — scanning")
struct PiholeDiscoveryServiceScanTests {
  private let mockSession = MockURLSession()
  private let mockDNS = MockEffectiveDNSServerResolver()

  @Test("returns empty when localIP is nil — no network calls")
  func nilLocalIP() async {
    let mockNetwork = MockLocalIPAddressResolver()
    mockNetwork.stubbedIP = nil
    let service = PiholeDiscoveryService(
      networkInterface: mockNetwork, dnsServerResolver: mockDNS, urlSession: mockSession)

    await service.scan()

    #expect(service.isScanning == false)
    #expect(service.discoveredInstances.isEmpty)
    #expect(mockSession.requests.isEmpty)
  }

  @Test("guards against concurrent scans")
  func concurrentGuard() async {
    let mockNetwork = MockLocalIPAddressResolver()
    mockNetwork.stubbedIP = "192.168.1.100"
    let service = PiholeDiscoveryService(
      networkInterface: mockNetwork, dnsServerResolver: mockDNS, urlSession: mockSession)

    // All 254 checks will throw, completing quickly
    mockSession.handlers = unreachableHandlers()

    let task1 = Task { await service.scan() }
    try? await Task.sleep(nanoseconds: UInt64(50 * 1_000_000))

    let scanningDuring = service.isScanning

    let task2 = Task { await service.scan() }
    try? await Task.sleep(nanoseconds: UInt64(50 * 1_000_000))

    await task1.value
    await task2.value

    #expect(scanningDuring)
    #expect(service.isScanning == false)
    #expect(service.discoveredInstances.isEmpty)
  }

  @Test("scan full pipeline — no reachable instances")
  func allUnreachable() async {
    let mockNetwork = MockLocalIPAddressResolver()
    mockNetwork.stubbedIP = "192.168.1.100"
    let service = PiholeDiscoveryService(
      networkInterface: mockNetwork, dnsServerResolver: mockDNS, urlSession: mockSession)

    mockSession.handlers = unreachableHandlers()

    await service.scan()

    #expect(service.discoveredInstances.isEmpty)
    #expect(service.isScanning == false)
  }
}

// MARK: - Instance detection (through scan)

@MainActor
@Suite("PiholeDiscoveryService — instance detection")
struct PiholeDiscoveryServiceDetectionTests {
  private let mockSession = MockURLSession()
  private let mockDNS = MockEffectiveDNSServerResolver()
  private let mockNetwork: MockLocalIPAddressResolver
  private let service: PiholeDiscoveryService

  init() {
    mockNetwork = MockLocalIPAddressResolver()
    mockNetwork.stubbedIP = "192.168.1.100"
    service = PiholeDiscoveryService(networkInterface: mockNetwork, dnsServerResolver: mockDNS, urlSession: mockSession)
  }

  private func makeResponse(statusCode: Int = 200, url: URL) -> HTTPURLResponse? {
    HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: "HTTP/1.1", headerFields: nil)
  }

  // MARK: - Response data helpers

  private func piholeAdminPageHTML(title: String = "Pi-hole Admin") -> Data {
    Data("<html><title>\(title)</title></html>".utf8)
  }

  private func piholeBodyPageHTML(body: String = "pihole web interface") -> Data {
    Data("<html>\(body)</html>".utf8)
  }

  private func genericPageHTML(body: String = "Some server page") -> Data {
    Data("<html>\(body)</html>".utf8)
  }

  private func apiInfoData(version: String = "v6.0") -> Data {
    Data("{\"version\":\"\(version)\"}".utf8)
  }

  @Test("detects Pi-hole via admin page title")
  func adminPageTitleMatch() async {
    mockSession.handlers = scanHandlers(responders: [
      42: { request in
        let url = try #require(request.url)
        let response = try #require(self.makeResponse(url: url))
        return (piholeAdminPageHTML(), response)
      }
    ])

    await service.scan()

    #expect(service.discoveredInstances.count == 1)
    #expect(service.discoveredInstances[0].addr == "192.168.1.42")
  }

  @Test("detects Pi-hole via body text (case-insensitive)")
  func bodyTextMatch() async {
    mockSession.handlers = scanHandlers(responders: [
      99: { request in
        let url = try #require(request.url)
        let response = try #require(self.makeResponse(url: url))
        return (piholeBodyPageHTML(), response)
      }
    ])

    await service.scan()

    #expect(service.discoveredInstances.count == 1)
    #expect(service.discoveredInstances[0].addr == "192.168.1.99")
  }

  @Test("falls back to v6 /api/info when admin page has no Pi-hole content")
  func v6ApiFallback() async {
    mockSession.handlers = scanHandlers(
      responders: [
        77: { request in
          if request.url?.path.hasPrefix("/admin") == true {
            let url = try #require(request.url)
            let response = try #require(self.makeResponse(url: url))
            return (genericPageHTML(), response)
          }
          #expect(request.url?.path == "/api/info")
          let url = try #require(request.url)
          let response = try #require(self.makeResponse(url: url))
          return (apiInfoData(), response)
        }
      ],
      twoCallHosts: [77]
    )

    await service.scan()

    #expect(service.discoveredInstances.count == 1)
    #expect(service.discoveredInstances[0].addr == "192.168.1.77")
  }

  @Test("admin page with non-200 status does not match")
  func adminPageNon200() async {
    mockSession.handlers = scanHandlers(responders: [
      55: { request in
        let url = try #require(request.url)
        let response = try #require(self.makeResponse(statusCode: 404, url: url))
        return (Data("Not Found".utf8), response)
      }
    ])

    await service.scan()
    #expect(service.discoveredInstances.isEmpty)
  }

  @Test("discovers multiple instances of different versions in one scan")
  func multipleInstancesMixedVersions() async {
    mockSession.handlers = scanHandlers(
      responders: [
        10: { request in
          // v5-style: admin page with Pi-hole in title
          let url = try #require(request.url)
          let response = try #require(self.makeResponse(url: url))
          return (piholeAdminPageHTML(), response)
        },
        42: { request in
          // v5-style: admin page with case-insensitive body match
          let url = try #require(request.url)
          let response = try #require(self.makeResponse(url: url))
          return (piholeBodyPageHTML(body: "PiHole Dashboard"), response)
        },
        77: { request in
          // v6-style: admin page non-Pi-hole → fallback to /api/info
          if request.url?.path.hasPrefix("/admin") == true {
            let url = try #require(request.url)
            let response = try #require(self.makeResponse(url: url))
            return (genericPageHTML(body: "Some other page"), response)
          }
          #expect(request.url?.path == "/api/info")
          let url = try #require(request.url)
          let response = try #require(self.makeResponse(url: url))
          return (apiInfoData(), response)
        },
        128: { request in
          // v6-style: fallback to /api/info
          if request.url?.path.hasPrefix("/admin") == true {
            let url = try #require(request.url)
            let response = try #require(self.makeResponse(url: url))
            return (genericPageHTML(body: "Nginx default page"), response)
          }
          let url = try #require(request.url)
          let response = try #require(self.makeResponse(url: url))
          return (apiInfoData(version: "v5.15"), response)
        },
        200: { request in
          // v5-style: admin page with "pihole" in body text
          let url = try #require(request.url)
          let response = try #require(self.makeResponse(url: url))
          return (piholeBodyPageHTML(body: "Welcome to pihole"), response)
        }
      ],
      twoCallHosts: [77, 128]
    )

    await service.scan()

    #expect(service.discoveredInstances.count == 5)
    #expect(service.discoveredInstances[0].addr == "192.168.1.10")
    #expect(service.discoveredInstances[1].addr == "192.168.1.42")
    #expect(service.discoveredInstances[2].addr == "192.168.1.77")
    #expect(service.discoveredInstances[3].addr == "192.168.1.128")
    #expect(service.discoveredInstances[4].addr == "192.168.1.200")
  }
}

// MARK: - DNS server discovery

@MainActor
@Suite("PiholeDiscoveryService — DNS server discovery")
struct PiholeDiscoveryServiceDNSTests {
  private let mockSession = MockURLSession()
  private let mockDNS = MockEffectiveDNSServerResolver()

  private func makeService(localIP: String?) -> PiholeDiscoveryService {
    let mockNetwork = MockLocalIPAddressResolver()
    mockNetwork.stubbedIP = localIP
    return PiholeDiscoveryService(
      networkInterface: mockNetwork,
      dnsServerResolver: mockDNS,
      urlSession: mockSession
    )
  }

  private func makeResponse(url: URL, statusCode: Int = 200) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: "HTTP/1.1", headerFields: nil)!
  }

  private func piholeAdminPage() -> Data {
    Data("<html><title>Pi-hole Admin</title></html>".utf8)
  }

  @Test("discovers a remote Pi-hole via effective DNS servers when no local network")
  func discoversViaDNS() async {
    mockDNS.stubbedServers = ["10.0.0.5"]
    mockSession.handlers = [
      handler(forAddr: "10.0.0.5") { request in
        let url = try #require(request.url)
        return (piholeAdminPage(), makeResponse(url: url))
      }
    ]

    let service = makeService(localIP: nil)
    await service.scan()

    #expect(service.discoveredInstances.count == 1)
    #expect(service.discoveredInstances[0].addr == "10.0.0.5")
    #expect(mockSession.requests.count == 1)
    #expect(mockSession.requests[0].url?.host() == "10.0.0.5")
  }

  @Test("never probes well-known public resolvers")
  func skipsIgnoredResolvers() async {
    mockDNS.stubbedServers = ["1.1.1.1", "8.8.8.8", "9.9.9.9", "208.67.222.222"]
    mockSession.handlers = []

    let service = makeService(localIP: nil)
    await service.scan()

    #expect(mockSession.requests.isEmpty)
    #expect(service.discoveredInstances.isEmpty)
  }

  @Test("skips IPv6 DNS servers")
  func skipsIPv6Servers() async {
    mockDNS.stubbedServers = ["fe80::1%en0", "2001:4860:4860::8888", "fd00::1"]
    mockSession.handlers = []

    let service = makeService(localIP: nil)
    await service.scan()

    #expect(mockSession.requests.isEmpty)
  }

  @Test("filters non-canonical IPv4 forms from DNS candidates")
  func filtersNonCanonicalIPv4() async {
    mockDNS.stubbedServers = ["1.1.1.01", "010.0.0.1", "999.1.1.1", "10.0.0.5", "10.0.0.6"]
    mockSession.handlers = [
      handler(forAddr: "10.0.0.5") { request in
        let url = try #require(request.url)
        return (piholeAdminPage(), makeResponse(url: url))
      },
      handler(forAddr: "10.0.0.6") { request in
        let url = try #require(request.url)
        return (piholeAdminPage(), makeResponse(url: url))
      }
    ]

    let service = makeService(localIP: nil)
    await service.scan()

    #expect(service.discoveredInstances.map(\.addr) == ["10.0.0.5", "10.0.0.6"])
    let probedHosts = Set(mockSession.requests.compactMap { $0.url?.host() })
    #expect(probedHosts == ["10.0.0.5", "10.0.0.6"])
  }

  @Test("probes a DNS candidate overlapping the subnet only once")
  func dedupesAgainstSubnet() async {
    mockDNS.stubbedServers = ["192.168.1.42"]
    mockSession.handlers = scanHandlers(responders: [
      42: { request in
        let url = try #require(request.url)
        return (piholeAdminPage(), makeResponse(url: url))
      }
    ])

    let service = makeService(localIP: "192.168.1.100")
    await service.scan()

    #expect(service.discoveredInstances.count == 1)
    #expect(service.discoveredInstances[0].addr == "192.168.1.42")
    let requestsTo42 = mockSession.requests.filter { $0.url?.host() == "192.168.1.42" }
    #expect(requestsTo42.count == 1)
  }

  @Test("non-Pi-hole DNS server is not discovered")
  func skipsNonPihole() async {
    mockDNS.stubbedServers = ["10.0.0.9"]
    let nonPihole = handler(forAddr: "10.0.0.9") { request in
      let url = try #require(request.url)
      if request.url?.path.hasPrefix("/admin") == true {
        return (Data("<html>Generic server page</html>".utf8), makeResponse(url: url))
      }
      #expect(request.url?.path == "/api/info")
      return (Data("not json".utf8), makeResponse(url: url))
    }
    mockSession.handlers = [nonPihole, nonPihole]

    let service = makeService(localIP: nil)
    await service.scan()

    #expect(service.discoveredInstances.isEmpty)
  }

  @Test("merges subnet and DNS results, sorted")
  func mergesSources() async {
    mockDNS.stubbedServers = ["10.0.0.5"]
    mockSession.handlers =
      scanHandlers(responders: [
        42: { request in
          let url = try #require(request.url)
          return (piholeAdminPage(), makeResponse(url: url))
        }
      ]) + [
        handler(forAddr: "10.0.0.5") { request in
          let url = try #require(request.url)
          return (piholeAdminPage(), makeResponse(url: url))
        }
      ]

    let service = makeService(localIP: "192.168.1.100")
    await service.scan()

    #expect(service.discoveredInstances.count == 2)
    #expect(service.discoveredInstances[0].addr == "10.0.0.5")
    #expect(service.discoveredInstances[1].addr == "192.168.1.42")
  }
}
