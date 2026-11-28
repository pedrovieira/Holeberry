import Foundation

extension String {
  /// The URL hostname when this string has a nonempty one.
  public var hostname: String? {
    guard let host = URLComponents(string: self)?.host, !host.isEmpty else { return nil }
    return host
  }
}
