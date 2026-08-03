import Foundation
import Testing

@testable import HoleberryCore

@Suite("PiholeServiceFactory")
@MainActor
struct PiholeServiceFactoryTests {
  @Test("v6 config creates PiholeV6Service wrapped in decorator")
  func v6CreatesV6Service() throws {
    let mockAuthFactory = MockAuthSessionFactory()
    let mockProvider = MockAuthSessionProvider()
    mockAuthFactory.stubbedProvider = mockProvider
    let factory = ConcretePiholeServiceFactory(authSessionFactory: mockAuthFactory, htmlParser: PiholeV5HTMLParser())

    let config = ServerConfig(label: "Test", url: "http://test.local", version: .v6)
    let service = try factory.buildService(
      config: config,
      credential: "password",
      session: URLSession.shared
    )

    // The factory wraps the raw service in TemporaryUnblockPiholeServiceDecorator.
    // The decorator is internal, so we verify behavior rather than type.
    #expect(service.id == config.id)
    #expect(service.label == "Test")
    #expect(service.url == "http://test.local")
    #expect(service.version == .v6)
  }

  @Test("v5 config creates PiholeV5Service wrapped in decorator")
  func v5CreatesV5Service() throws {
    let mockAuthFactory = MockAuthSessionFactory()
    let factory = ConcretePiholeServiceFactory(authSessionFactory: mockAuthFactory, htmlParser: PiholeV5HTMLParser())

    let config = ServerConfig(label: "v5 Test", url: "http://v5.local", version: .v5)
    let service = try factory.buildService(
      config: config,
      credential: "api-token",
      session: URLSession.shared
    )

    #expect(service.id == config.id)
    #expect(service.label == "v5 Test")
    #expect(service.url == "http://v5.local")
    #expect(service.version == .v5)
  }
}
