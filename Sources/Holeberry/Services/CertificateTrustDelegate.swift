import Foundation

/// URL session delegate that trusts self-signed TLS certificates for user-approved hosts.
final class CertificateTrustDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
  private let trustedHostsProvider: () -> Set<String>
  private let onUntrustedHost: ((String) -> Void)?

  init(
    trustedHosts: @escaping @autoclosure () -> Set<String>,
    onUntrustedHost: ((String) -> Void)? = nil
  ) {
    self.trustedHostsProvider = trustedHosts
    self.onUntrustedHost = onUntrustedHost
  }

  func urlSession(
    _ session: URLSession,
    didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    let protectionSpace = challenge.protectionSpace
    guard protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
      let host = protectionSpace.host as String?,
      let serverTrust = protectionSpace.serverTrust
    else {
      completionHandler(.performDefaultHandling, nil)
      return
    }

    if trustedHostsProvider().contains(host) {
      completionHandler(.useCredential, URLCredential(trust: serverTrust))
    } else {
      onUntrustedHost?(host)
      completionHandler(.performDefaultHandling, nil)
    }
  }
}
