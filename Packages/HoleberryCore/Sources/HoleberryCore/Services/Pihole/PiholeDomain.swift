import Foundation

/// Shared identity for exact domain entries, including persisted unblock records.
enum PiholeDomain {
  static func identity(_ domain: String) -> String {
    // Do not interpret paths, credentials, ports, or escapes as part of a hostname.
    let delimiters = CharacterSet(charactersIn: "/\\:@?#%")
      .union(.whitespacesAndNewlines).union(.controlCharacters)
    guard domain.rangeOfCharacter(from: delimiters) == nil else { return domain.lowercased() }
    return (URL(string: "http://\(domain)")?.host ?? domain).lowercased()
  }

  static func validatedIdentity(_ domain: String) throws -> String {
    let identity = identity(domain)
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-._")
    guard !identity.isEmpty, !identity.hasPrefix("."), !identity.contains(".."),
      identity.rangeOfCharacter(from: allowed.inverted) == nil
    else {
      throw PiholeError.invalidDomain(domain)
    }
    return identity
  }
}
