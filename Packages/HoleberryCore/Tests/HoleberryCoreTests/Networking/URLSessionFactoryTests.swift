import Foundation
import Testing

@testable import HoleberryCore

@MainActor
@Suite("URLSessionFactory")
struct URLSessionFactoryTests {
  @Test("concrete factory returns a URLSession with the certificate-trust delegate")
  func concreteFactoryAttachesTrustDelegate() throws {
    let session = ConcreteURLSessionFactory().makeSession(
      configuration: .ephemeral,
      trustedHosts: ["pihole.local"]
    )
    let urlSession = try #require(session as? URLSession)

    #expect(urlSession.delegate is CertificateTrustDelegate)
    urlSession.invalidateAndCancel()
  }

  @Test("concrete factory preserves the caller's configuration")
  func concreteFactoryPreservesConfiguration() throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 12
    let session = ConcreteURLSessionFactory().makeSession(
      configuration: configuration,
      trustedHosts: []
    )
    let urlSession = try #require(session as? URLSession)

    #expect(urlSession.configuration.timeoutIntervalForRequest == 12)
    urlSession.invalidateAndCancel()
  }
}
