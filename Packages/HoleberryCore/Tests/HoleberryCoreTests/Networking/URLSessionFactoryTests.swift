import Foundation
import Security
import Testing

@testable import HoleberryCore

/// Throwaway self-signed certificate used only to build a `SecTrust` for the
/// delegate's synthetic server-trust challenge. These tests never evaluate it,
/// connect to a network, or touch the user's keychain.
private let testCertificateDER = """
  MIIDCzCCAfOgAwIBAgIUNvqs8W/RgINsr3ilk1o3pGLka3cwDQYJKoZIhvcNAQELBQAwGTEXMBUG
  A1UEAwwOaG9sZWJlcnJ5LnRlc3QwHhcNMjYxMTI0MTEwMzQ5WhcNMzYxMTIxMTEwMzQ5WjAZMRcw
  FQYDVQQDDA5ob2xlYmVycnkudGVzdDCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBAMdR
  tLE2bcE47OauVF/BzbW+NuadFNf37URvB2rfd+B6b+NYf16M6aBrxTRTyrkp4wAPrF5VWBjp7Bq0
  e85carSumWD4yWgJeNEjTgx+xfFyai58/XJ0NBlQw/0LEz9JI7FMi5yqgG/XoR1cHjRqrkJlWGC3
  dfQQ8I7S4QSyyQR8q8xZuuoHxLf8DD3bWCDTyMvL5lslWk2YknQmQ66DIYv9oRw0lSjLqjk67qG5
  lfWqTilRYVCgu7R27YOrrmBvL50JV4RwcPBZc26cC34KBHtP1K11Uu32B9xhWUSpS1ZwtPELAHyr
  LYJvMQc+DBuSwHKIDY8Jjs07cO78r0/Zz60CAwEAAaNLMEkwHQYDVR0OBBYEFEy9Zelh645hGMj9
  VcYPUUP3AN5UMA8GA1UdEwEB/wQFMAMBAf8wFwYDVR0RBBAwDoIMcGlob2xlLmxvY2FsMA0GCSqG
  SIb3DQEBCwUAA4IBAQB39qtqFGED9uFllw90Hb/Xj81GmqZz4utoWsNWvzjFIzZD06N06LGxX1GA
  11R+GUncQOP5FPtgb+rM3VkNSXpI+CW53DkckNwXA1eP3nse+wcQpL/3HGEojkj5IpYSxCHDPiGr
  jmqW4lt9Pc9OHSaY8p7BAG8pLXed3Wv6sf++PjlMqS+T9L0UZpOAoJ2zGLrAMCGsoWi7Qri2vnyv
  fz/f1+9X9K8eYGAQhT1Bfm2N2WDxJ7pEbi3G1pfdYAN8oPggLBP+5eCraO7sKOQHtKceZiomLuHf
  DoCz69VAp20O0GvyfcN7HGU2wnrGe9cVATTOA467VguMDk1HIm5rXfbh
  """

/// A protection space carrying a supplied trust. Public Foundation has no
/// initializer that attaches a `SecTrust`, and the delegate needs only `host`
/// plus `serverTrust`, so the test supplies both.
private final class ServerTrustProtectionSpace: URLProtectionSpace, @unchecked Sendable {
  private let trust: SecTrust

  init(host: String, trust: SecTrust) {
    self.trust = trust
    super.init(
      host: host,
      port: 443,
      protocol: "https",
      realm: nil,
      authenticationMethod: NSURLAuthenticationMethodServerTrust
    )
  }

  required init?(coder: NSCoder) {
    fatalError("unused")
  }

  override var serverTrust: SecTrust? { trust }
}

private final class StubChallengeSender: NSObject, URLAuthenticationChallengeSender {
  func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
  func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
  func cancel(_ challenge: URLAuthenticationChallenge) {}
}

/// A not-evaluated trust: the delegate only checks host membership and that a
/// trust exists.
private func makeServerTrust() throws -> SecTrust {
  let data = try #require(
    Data(base64Encoded: testCertificateDER, options: .ignoreUnknownCharacters))
  let certificate = try #require(SecCertificateCreateWithData(nil, data as CFData))
  var trust: SecTrust?
  let status = SecTrustCreateWithCertificates(
    certificate, SecPolicyCreateSSL(true, "pihole.local" as CFString), &trust)
  #expect(status == errSecSuccess)
  return try #require(trust)
}

private func makeChallenge(host: String, trust: SecTrust) -> URLAuthenticationChallenge {
  URLAuthenticationChallenge(
    protectionSpace: ServerTrustProtectionSpace(host: host, trust: trust),
    proposedCredential: nil,
    previousFailureCount: 0,
    failureResponse: nil,
    error: nil,
    sender: StubChallengeSender()
  )
}

@MainActor
@Suite("ConcreteURLSessionFactory")
struct ConcreteURLSessionFactoryTests {
  private func makeSession(
    configuration: URLSessionConfiguration = .ephemeral,
    trustedHosts: Set<String> = ["pihole.local"]
  ) throws -> URLSession {
    let factory = ConcreteURLSessionFactory()
    return try #require(
      factory.makeSession(configuration: configuration, trustedHosts: trustedHosts) as? URLSession)
  }

  private func disposition(
    _ delegate: CertificateTrustDelegate,
    _ session: URLSession,
    _ challenge: URLAuthenticationChallenge
  ) throws -> (URLSession.AuthChallengeDisposition, URLCredential?) {
    var result: URLSession.AuthChallengeDisposition?
    var credential: URLCredential?
    var completionCount = 0
    delegate.urlSession(session, didReceive: challenge) { disposition, proposed in
      completionCount += 1
      result = disposition
      credential = proposed
    }
    let final = try #require(result, "the delegate must call the completion handler")
    #expect(completionCount == 1, "the delegate must call the completion handler exactly once")
    return (final, credential)
  }

  @Test func createsAnEphemeralSessionWithTheTrustDelegate() throws {
    let session = try makeSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }

    #expect(session.delegate is CertificateTrustDelegate)
    let configuration = session.configuration
    #expect(configuration.httpCookieStorage !== HTTPCookieStorage.shared)
    let cache = try #require(configuration.urlCache, "an ephemeral session still has a cache")
    #expect(cache.diskCapacity == 0, "the cache is memory-only")
    #expect(cache !== URLCache.shared)
    #expect(configuration.urlCredentialStorage !== URLCredentialStorage.shared)
  }

  @Test func acceptsConfiguredHostsAndDeclinesOtherHosts() throws {
    let session = try makeSession(trustedHosts: ["pihole.local"])
    defer { session.invalidateAndCancel() }
    let delegate = try #require(session.delegate as? CertificateTrustDelegate)
    let trust = try makeServerTrust()

    let trusted = try disposition(delegate, session, makeChallenge(host: "pihole.local", trust: trust))
    #expect(trusted.0 == .useCredential)
    #expect(trusted.1 != nil)

    let other = try disposition(delegate, session, makeChallenge(host: "other.local", trust: trust))
    #expect(other.0 == .performDefaultHandling)
    #expect(other.1 == nil)
  }

  @Test func honorsTheSuppliedConfiguration() throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 12
    let session = try makeSession(configuration: configuration)
    defer { session.invalidateAndCancel() }

    #expect(session.configuration.timeoutIntervalForRequest == 12)
    #expect(session.delegate is CertificateTrustDelegate)
  }

  @Test func nonServerTrustChallengesUseDefaultHandling() throws {
    let session = try makeSession()
    defer { session.invalidateAndCancel() }
    let delegate = try #require(session.delegate as? CertificateTrustDelegate)
    let space = URLProtectionSpace(
      host: "pihole.local",
      port: 443,
      protocol: "https",
      realm: nil,
      authenticationMethod: NSURLAuthenticationMethodHTTPBasic
    )
    let challenge = URLAuthenticationChallenge(
      protectionSpace: space,
      proposedCredential: nil,
      previousFailureCount: 0,
      failureResponse: nil,
      error: nil,
      sender: StubChallengeSender()
    )

    let result = try disposition(delegate, session, challenge)

    #expect(result.0 == .performDefaultHandling)
    #expect(result.1 == nil)
  }
}
