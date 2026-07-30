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

  private let networkInterface: LocalIPAddressProviding
  private let urlSession: any HTTPRequestable

  public init(
    networkInterface: LocalIPAddressProviding = LocalIPAddressResolver(),
    urlSession: any HTTPRequestable = URLSession.shared
  ) {
    self.networkInterface = networkInterface
    self.urlSession = urlSession
  }

  public func scan() async {
    guard !isScanning else { return }
    isScanning = true
    discoveredInstances = await scanSubnet(localIPAddressResolver: networkInterface)
    isScanning = false
  }

  // MARK: - Scanning

  /// Scans the local /24 subnet for Pi-hole admin endpoints.
  /// Best-effort: unreachable IPs are silently skipped.
  /// Respects cooperative cancellation.
  private func scanSubnet(localIPAddressResolver: LocalIPAddressProviding) async -> [DiscoveredInstance] {
    guard let localIP = localIPAddressResolver.localIPAddress() else { return [] }

    let components = localIP.split(separator: ".")
    guard components.count == 4 else { return [] }
    let prefix = components[0...2].joined(separator: ".")

    return await withTaskGroup(of: DiscoveredInstance?.self) { group in
      for i in 1...254 {
        let addr = "\(prefix).\(i)"
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
