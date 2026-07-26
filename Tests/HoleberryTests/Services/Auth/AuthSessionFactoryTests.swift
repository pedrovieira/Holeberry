import Foundation
import Testing

@testable import Holeberry

@Suite("ConcreteAuthSessionFactory")
struct ConcreteAuthSessionFactoryTests {
  @Test("Throws for v5")
  func throwsForV5() {
    let factory = ConcreteAuthSessionFactory()
    #expect(throws: PiholeError.unknown("Auth session is only supported for Pi-hole v6")) {
      try factory.makeSession(
        host: URL(string: "http://test.local")!,
        password: "pass",
        urlSession: URLSession.shared,
        piHoleVersion: .v5
      )
    }
  }

  @Test("Returns AuthV6SessionProvider for v6")
  func returnsProviderForV6() throws {
    let factory = ConcreteAuthSessionFactory()
    let provider = try factory.makeSession(
      host: URL(string: "http://test.local")!,
      password: "pass",
      urlSession: URLSession.shared,
      piHoleVersion: .v6
    )
    #expect(provider is AuthV6SessionProvider)
  }
}
