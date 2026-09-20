import Foundation

extension URL {
  /// The host of an http(s) URL; nil for internal browser pages (`about:`,
  /// `chrome://…`) and any other URL without a host.
  var domain: String? {
    guard let scheme = scheme?.lowercased(), scheme == "http" || scheme == "https" else {
      return nil
    }
    guard let host, !host.isEmpty else {
      return nil
    }
    return host
  }
}
