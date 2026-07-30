import Darwin
import Foundation

// MARK: - Protocol

public protocol LocalIPAddressProviding: Sendable {
  /// Returns the local IPv4 address string (e.g. "192.168.1.67"), or `nil` if no active interface is found.
  func localIPAddress() -> String?
}

// MARK: - Concrete Implementation

/// Resolves the Mac's current local IPv4 address from the primary network interface.
public final class LocalIPAddressResolver: LocalIPAddressProviding {
  public init() {}

  public func localIPAddress() -> String? {
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0 else { return nil }
    defer { freeifaddrs(ifaddr) }

    var ptr = ifaddr
    while let ifa = ptr {
      defer { ptr = ifa.pointee.ifa_next }

      // Guard against nil ifa_addr (can happen on PPP/VPN interfaces)
      guard let ifaAddr = ifa.pointee.ifa_addr else { continue }
      guard ifaAddr.pointee.sa_family == UInt8(AF_INET) else { continue }

      // Accept any Ethernet/Wi-Fi interface (en0, en1, en2, …)
      let name = String(cString: ifa.pointee.ifa_name)
      guard name.hasPrefix("en") else { continue }

      // Skip interfaces that are not up/running
      let flags = ifa.pointee.ifa_flags
      guard (flags & UInt32(IFF_UP)) != 0, (flags & UInt32(IFF_RUNNING)) != 0 else { continue }

      var addr = ifaAddr.pointee
      let ipAddr = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin -> String? in
          var address = sin.pointee.sin_addr
          let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: Int(INET_ADDRSTRLEN))
          defer { buffer.deallocate() }
          guard inet_ntop(AF_INET, &address, buffer, socklen_t(INET_ADDRSTRLEN)) != nil else {
            return nil
          }
          return String(cString: buffer)
        }
      }
      if let ipAddr { return ipAddr }  // keep looking if inet_ntop failed
    }
    return nil
  }
}
