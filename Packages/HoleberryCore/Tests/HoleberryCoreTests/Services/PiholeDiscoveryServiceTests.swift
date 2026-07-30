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

// MARK: - Scanning

@MainActor
@Suite("PiholeDiscoveryService — scanning")
struct PiholeDiscoveryServiceScanTests {
  private let mockSession = MockURLSession()

  @Test("returns empty when localIP is nil — no network calls")
  func nilLocalIP() async {
    let mockNetwork = MockLocalIPAddressResolver()
    mockNetwork.stubbedIP = nil
    let service = PiholeDiscoveryService(networkInterface: mockNetwork, urlSession: mockSession)

    await service.scan()

    #expect(!service.isScanning)
    #expect(service.discoveredInstances.isEmpty)
    #expect(mockSession.requests.isEmpty)
  }

  @Test("guards against concurrent scans")
  func concurrentGuard() async {
    let mockNetwork = MockLocalIPAddressResolver()
    mockNetwork.stubbedIP = "192.168.1.100"
    let service = PiholeDiscoveryService(networkInterface: mockNetwork, urlSession: mockSession)

    // All 254 checks will throw, completing quickly
    mockSession.handlers = Array(repeating: { _ in throw URLError(.notConnectedToInternet) }, count: 254)

    let task1 = Task { await service.scan() }
    try? await Task.sleep(for: .milliseconds(50))

    let scanningDuring = service.isScanning

    let task2 = Task { await service.scan() }
    try? await Task.sleep(for: .milliseconds(50))

    await task1.value
    await task2.value

    #expect(scanningDuring)
    #expect(!service.isScanning)
    #expect(service.discoveredInstances.isEmpty)
  }

  @Test("scan full pipeline — no reachable instances")
  func allUnreachable() async {
    let mockNetwork = MockLocalIPAddressResolver()
    mockNetwork.stubbedIP = "192.168.1.100"
    let service = PiholeDiscoveryService(networkInterface: mockNetwork, urlSession: mockSession)

    mockSession.handlers = Array(repeating: { _ in throw URLError(.notConnectedToInternet) }, count: 254)

    await service.scan()

    #expect(service.discoveredInstances.isEmpty)
    #expect(!service.isScanning)
  }
}

// MARK: - Instance detection (through scan)

@MainActor
@Suite("PiholeDiscoveryService — instance detection")
struct PiholeDiscoveryServiceDetectionTests {
  private let mockSession = MockURLSession()
  private let mockNetwork: MockLocalIPAddressResolver
  private let service: PiholeDiscoveryService

  init() {
    mockNetwork = MockLocalIPAddressResolver()
    mockNetwork.stubbedIP = "192.168.1.100"
    service = PiholeDiscoveryService(networkInterface: mockNetwork, urlSession: mockSession)
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
    mockSession.handlers = (1...254).map { idx in
      { request in
        let url = try #require(request.url)
        if idx == 42 {
          let response = try #require(self.makeResponse(url: url))
          return (piholeAdminPageHTML(), response)
        }
        throw URLError(.notConnectedToInternet)
      }
    }

    await service.scan()

    #expect(service.discoveredInstances.count == 1)
    #expect(service.discoveredInstances[0].addr == "192.168.1.42")
  }

  @Test("detects Pi-hole via body text (case-insensitive)")
  func bodyTextMatch() async {
    mockSession.handlers = (1...254).map { idx in
      { request in
        let url = try #require(request.url)
        if idx == 99 {
          let response = try #require(self.makeResponse(url: url))
          return (piholeBodyPageHTML(), response)
        }
        throw URLError(.notConnectedToInternet)
      }
    }

    await service.scan()

    #expect(service.discoveredInstances.count == 1)
    #expect(service.discoveredInstances[0].addr == "192.168.1.99")
  }

  @Test("falls back to v6 /api/info when admin page has no Pi-hole content")
  func v6ApiFallback() async {
    mockSession.handlers = (1...254).map { idx in
      { request in
        let url = try #require(request.url)
        if idx != 77 { throw URLError(.notConnectedToInternet) }
        if request.url?.path == "/admin/" || request.url?.path.hasPrefix("/admin") == true {
          let response = try #require(self.makeResponse(url: url))
          return (genericPageHTML(), response)
        }
        #expect(request.url?.path == "/api/info")
        let response = try #require(self.makeResponse(url: url))
        return (apiInfoData(), response)
      }
    }

    await service.scan()

    #expect(service.discoveredInstances.count == 1)
    #expect(service.discoveredInstances[0].addr == "192.168.1.77")
  }

  @Test("admin page with non-200 status does not match")
  func adminPageNon200() async {
    mockSession.handlers = (1...254).map { idx in
      { request in
        let url = try #require(request.url)
        if idx == 55 {
          let response = try #require(self.makeResponse(statusCode: 404, url: url))
          return (Data("Not Found".utf8), response)
        }
        throw URLError(.notConnectedToInternet)
      }
    }

    await service.scan()
    #expect(service.discoveredInstances.isEmpty)
  }

  @Test("discovers multiple instances of different versions in one scan")
  func multipleInstancesMixedVersions() async {
    mockSession.handlers = (1...254).map { idx in
      { request in
        let url = try #require(request.url)
        switch idx {
        case 10:
          // v5-style: admin page with Pi-hole in title
          let response = try #require(self.makeResponse(url: url))
          return (piholeAdminPageHTML(), response)
        case 42:
          // v5-style: admin page with case-insensitive body match
          let response = try #require(self.makeResponse(url: url))
          return (piholeBodyPageHTML(body: "PiHole Dashboard"), response)
        case 77:
          // v6-style: admin page non-Pi-hole → fallback to /api/info
          if request.url?.path == "/admin/" || request.url?.path.hasPrefix("/admin") == true {
            let response = try #require(self.makeResponse(url: url))
            return (genericPageHTML(body: "Some other page"), response)
          }
          #expect(request.url?.path == "/api/info")
          let response = try #require(self.makeResponse(url: url))
          return (apiInfoData(), response)
        case 128:
          // v6-style: fallback to /api/info
          if request.url?.path == "/admin/" || request.url?.path.hasPrefix("/admin") == true {
            let response = try #require(self.makeResponse(url: url))
            return (genericPageHTML(body: "Nginx default page"), response)
          }
          let response = try #require(self.makeResponse(url: url))
          return (apiInfoData(version: "v5.15"), response)
        case 200:
          // v5-style: admin page with "pihole" in body text
          let response = try #require(self.makeResponse(url: url))
          return (piholeBodyPageHTML(body: "Welcome to pihole"), response)
        default:
          throw URLError(.notConnectedToInternet)
        }
      }
    }

    await service.scan()

    #expect(service.discoveredInstances.count == 5)
    #expect(service.discoveredInstances[0].addr == "192.168.1.10")
    #expect(service.discoveredInstances[1].addr == "192.168.1.42")
    #expect(service.discoveredInstances[2].addr == "192.168.1.77")
    #expect(service.discoveredInstances[3].addr == "192.168.1.128")
    #expect(service.discoveredInstances[4].addr == "192.168.1.200")
  }
}
