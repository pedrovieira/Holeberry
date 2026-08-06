import Foundation
import SystemConfiguration

// MARK: - Protocol

public protocol EffectiveDNSServerProviding: Sendable {
  /// Returns the DNS servers macOS is currently using — the merged result
  /// across manual entries and DHCP, for the network service with priority.
  /// Returns `[]` when no DNS configuration is present.
  func effectiveDNSServers() -> [String]
}

// MARK: - Concrete Implementation

/// Reads the effective DNS server list from the SystemConfiguration dynamic store.
public final class EffectiveDNSServerResolver: EffectiveDNSServerProviding {
  public init() {}

  public func effectiveDNSServers() -> [String] {
    guard let store = SCDynamicStoreCreate(nil, "Holeberry" as CFString, nil, nil),
      let dnsDict = SCDynamicStoreCopyValue(store, "State:/Network/Global/DNS" as CFString) as? [String: Any],
      let servers = dnsDict["ServerAddresses"] as? [String]
    else {
      return []
    }
    return servers
  }
}
