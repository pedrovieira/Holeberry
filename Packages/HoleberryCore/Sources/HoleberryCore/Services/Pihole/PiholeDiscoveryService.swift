import Foundation

// MARK: - Model

extension PiholeDiscoveryService {
  public struct DiscoveredInstance: Identifiable, Sendable {
    public var id: String { addr }
    public let addr: String

    public var adminURL: URL {
      guard let url = URL(string: "http://\(addr)/admin") else {
        fatalError("Invalid URL for \(addr)")
      }
      return url
    }
  }
}

// MARK: - Service

@MainActor
public class PiholeDiscoveryService: ObservableObject {
  @Published public var discoveredInstances: [DiscoveredInstance] = []
  @Published public var isScanning = false

  /// Well-known public DNS resolvers. Probing them for a Pi-hole web interface
  /// would be pointless and sends requests to third parties, so they are skipped.
  private static let ignoredDNSServers: Set<String> = [
    // Cloudflare
    "1.1.1.1", "1.0.0.1", "1.1.1.2", "1.0.0.2", "1.1.1.3", "1.0.0.3",
    // Google
    "8.8.8.8", "8.8.4.4",
    // Quad9
    "9.9.9.9", "9.9.9.10", "9.9.9.11", "149.112.112.112", "149.112.112.10", "149.112.112.11",
    // OpenDNS
    "208.67.222.222", "208.67.220.220",
    // Comodo
    "8.26.56.26", "8.20.247.20",
    // AdGuard
    "94.140.14.14", "94.140.15.15", "94.140.14.15", "94.140.15.16",
    // NextDNS
    "45.90.28.0", "45.90.28.1", "45.90.28.2", "45.90.28.3",
    "45.90.30.0", "45.90.30.1", "45.90.30.2", "45.90.30.3",
    // Mullvad
    "194.242.2.2", "194.242.2.3",
    // DNS.SB
    "185.222.222.222", "45.11.45.11",
    // UncensoredDNS
    "91.239.100.100", "89.233.43.71",
    // Yandex
    "77.88.8.8", "77.88.8.1",
    // CleanBrowsing
    "185.228.168.9", "185.228.169.9", "185.228.168.10", "185.228.169.10",
    // Verisign
    "64.6.64.6", "64.6.65.6",
    // Neustar UltraDNS
    "156.154.70.1", "156.154.71.1"
  ]

  private let networkInterface: any LocalIPAddressProviding
  private let dnsServerResolver: any EffectiveDNSServerProviding
  private let urlSession: any HTTPRequestable

  public init(
    networkInterface: any LocalIPAddressProviding,
    dnsServerResolver: any EffectiveDNSServerProviding,
    urlSession: any HTTPRequestable = URLSession.shared
  ) {
    self.networkInterface = networkInterface
    self.dnsServerResolver = dnsServerResolver
    self.urlSession = urlSession
  }

  public func scan() async {
    guard !isScanning else { return }
    isScanning = true
    defer { isScanning = false }

    // Candidates from both sources; dedupe before probing so overlapping
    // entries (e.g. the router IP handed out via DHCP) are only probed once.
    var seen = Set<String>()
    let candidates =
      (Self.subnetCandidates(localIP: networkInterface.localIPAddress())
      + Self.dnsCandidates(servers: dnsServerResolver.effectiveDNSServers()))
      .filter { seen.insert($0).inserted }

    discoveredInstances = await probe(candidates: candidates)
  }

  // MARK: - Candidate sources

  /// All addresses in the local /24 subnet derived from the Mac's IPv4 address.
  private static func subnetCandidates(localIP: String?) -> [String] {
    guard let localIP else { return [] }
    let components = localIP.split(separator: ".")
    guard components.count == 4 else { return [] }
    let prefix = components[0...2].joined(separator: ".")
    return (1...254).map { "\(prefix).\($0)" }
  }

  /// Effective DNS servers worth probing: well-known public resolvers are skipped
  /// so discovery never sends requests to third parties, and IPv6 literals are
  /// skipped because `checkInstance` builds IPv4-style URLs.
  private static func dnsCandidates(servers: [String]) -> [String] {
    servers.filter { !ignoredDNSServers.contains($0) && isIPv4Address($0) }
  }

  private static func isIPv4Address(_ address: String) -> Bool {
    let components = address.split(separator: ".")
    guard components.count == 4 else { return false }
    return components.allSatisfy { component in
      // Reject leading zeros so only canonical IPv4 forms are probed.
      guard !(component.count > 1 && component.hasPrefix("0")),
        let value = Int(component), (0...255).contains(value)
      else { return false }
      return true
    }
  }

  // MARK: - Probing

  /// Probes all candidates in parallel for Pi-hole admin endpoints.
  /// Best-effort: unreachable IPs are silently skipped.
  /// Respects cooperative cancellation.
  private func probe(candidates: [String]) async -> [DiscoveredInstance] {
    await withTaskGroup(of: DiscoveredInstance?.self) { group in
      for addr in candidates {
        group.addTask { [weak self] in
          guard !Task.isCancelled else { return nil }
          return await self?.checkInstance(addr: addr)
        }
      }

      var instances: [DiscoveredInstance] = []
      for await result in group {
        if let instance = result, !Task.isCancelled {
          instances.append(instance)
        }
      }

      guard !Task.isCancelled else { return [] }

      return instances.sorted {
        $0.addr.localizedStandardCompare($1.addr) == .orderedAscending
      }
    }
  }

  private func checkInstance(addr: String) async -> DiscoveredInstance? {
    guard let adminURL = URL(string: "http://\(addr)/admin/") else { return nil }

    var request = URLRequest(url: adminURL)
    request.timeoutInterval = 2

    do {
      let (data, response) = try await urlSession.data(for: request)
      guard let http = response as? HTTPURLResponse,
        http.statusCode == 200,
        let body = String(data: data, encoding: .utf8)
      else { return nil }

      if body.contains("<title>Pi-hole") || body.localizedCaseInsensitiveContains("pihole") {
        return DiscoveredInstance(addr: addr)
      }
    } catch {
      // Silently skip unreachable hosts
    }

    // Fallback: try v6 API info endpoint
    guard let apiURL = URL(string: "http://\(addr)/api/info") else { return nil }

    var apiRequest = URLRequest(url: apiURL)
    apiRequest.timeoutInterval = 2

    do {
      let (data, response) = try await urlSession.data(for: apiRequest)
      guard let http = response as? HTTPURLResponse,
        http.statusCode == 200,
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        json["version"] != nil
      else { return nil }
      return DiscoveredInstance(addr: addr)
    } catch {
      return nil
    }
  }
}
