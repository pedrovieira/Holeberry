import XCTest
@testable import PiHoleMenuApp

@MainActor
final class TempUnblockManagerTests: XCTestCase {
  private let defaults = UserDefaults(suiteName: "TempUnblockManagerTests")!

  override func tearDown() {
    defaults.removePersistentDomain(forName: "TempUnblockManagerTests")
    super.tearDown()
  }

  // MARK: - add()

  func testAddAddsDomainToServer() async throws {
    let mock = MockPiholeService()
    mock.addDomainStub = .success(
      DomainEntry(id: 42, domain: "doubleclick.net", type: 0, comment: "pihole-menu-app:test-uuid")
    )
    let provider = MockServerProvider()
    provider.servers = [
      PiholeServer(label: "Main", url: "http://192.168.1.100", version: .v6)
    ]
    provider.makeService = { _ in mock }

    let manager = TempUnblockManager(serverProvider: provider, userDefaults: defaults)
    let record = try await manager.add(domain: "doubleclick.net", duration: 300)

    XCTAssertEqual(mock.addDomainCallCount, 1)
    XCTAssertEqual(mock.addDomainLastDomain, "doubleclick.net")
    XCTAssertEqual(mock.addDomainLastList, .allow)
    XCTAssertTrue(mock.addDomainLastComment?.hasPrefix("pihole-menu-app:") ?? false)
    XCTAssertEqual(record.domain, "doubleclick.net")
    XCTAssertEqual(record.durationSeconds, 300)
    XCTAssertFalse(record.pendingRemoval)
    XCTAssertEqual(manager.activeRecords.count, 1)
  }

  func testAddWithTwoServersCallsBoth() async throws {
    var callCount = 0
    let mock1 = MockPiholeService()
    mock1.addDomainStub = .success(
      DomainEntry(id: 42, domain: "doubleclick.net", type: 0, comment: "uuid-1")
    )
    let mock2 = MockPiholeService()
    mock2.addDomainStub = .success(
      DomainEntry(id: 17, domain: "doubleclick.net", type: 0, comment: "uuid-1")
    )

    let provider = MockServerProvider()
    provider.servers = [
      PiholeServer(label: "A", url: "http://192.168.1.100", version: .v6),
      PiholeServer(label: "B", url: "http://192.168.1.101", version: .v6)
    ]
    provider.makeService = { _ in
      defer { callCount += 1 }
      return callCount == 0 ? mock1 : mock2
    }

    let manager = TempUnblockManager(serverProvider: provider, userDefaults: defaults)
    let record = try await manager.add(domain: "doubleclick.net", duration: 300)

    XCTAssertEqual(mock1.addDomainCallCount, 1)
    XCTAssertEqual(mock2.addDomainCallCount, 1)
    XCTAssertEqual(record.domain, "doubleclick.net")
  }

  func testAddWithNoServersThrows() async {
    let provider = MockServerProvider()
    provider.servers = []

    let manager = TempUnblockManager(serverProvider: provider, userDefaults: defaults)
    do {
      _ = try await manager.add(domain: "test.com", duration: 60)
      XCTFail("Expected error")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("No configured"))
    }
    XCTAssertTrue(manager.activeRecords.isEmpty)
  }

  func testAddPartialSuccessCreatesRecord() async throws {
    var callCount = 0
    let goodMock = MockPiholeService()
    goodMock.addDomainStub = .success(
      DomainEntry(id: 42, domain: "test.com", type: 0, comment: "uuid-1")
    )
    let badMock = MockPiholeService()
    badMock.addDomainStub = .failure(PiholeError.network("timeout"))

    let provider = MockServerProvider()
    provider.servers = [
      PiholeServer(label: "A", url: "http://192.168.1.100", version: .v6),
      PiholeServer(label: "B", url: "http://192.168.1.101", version: .v6)
    ]
    provider.makeService = { _ in
      defer { callCount += 1 }
      return callCount == 0 ? goodMock : badMock
    }

    let manager = TempUnblockManager(serverProvider: provider, userDefaults: defaults)
    let record = try await manager.add(domain: "test.com", duration: 300)

    XCTAssertEqual(manager.activeRecords.count, 1)
    XCTAssertEqual(record.domain, "test.com")
  }

  func testAddTotalFailureThrows() async throws {
    let mock = MockPiholeService()
    mock.addDomainStub = .failure(PiholeError.server(500, "Internal"))

    let provider = MockServerProvider()
    provider.servers = [
      PiholeServer(label: "A", url: "http://192.168.1.100", version: .v6)
    ]
    provider.makeService = { _ in mock }

    let manager = TempUnblockManager(serverProvider: provider, userDefaults: defaults)
    do {
      _ = try await manager.add(domain: "test.com", duration: 60)
      XCTFail("Expected error")
    } catch {
      XCTAssertEqual(error as? PiholeError, .server(500, "Internal"))
    }
    XCTAssertTrue(manager.activeRecords.isEmpty)
  }

  func testAddWithAlreadyUnblockedDomainReturnsExisting() async throws {
    let mock = MockPiholeService()
    mock.addDomainStub = .success(
      DomainEntry(id: 42, domain: "doubleclick.net", type: 0, comment: "uuid-1")
    )

    let provider = MockServerProvider()
    provider.servers = [
      PiholeServer(label: "Main", url: "http://192.168.1.100", version: .v6)
    ]
    provider.makeService = { _ in mock }

    let manager = TempUnblockManager(serverProvider: provider, userDefaults: defaults)
    let first = try await manager.add(domain: "doubleclick.net", duration: 300)
    let second = try await manager.add(domain: "doubleclick.net", duration: 300)

    XCTAssertEqual(mock.addDomainCallCount, 1)
    XCTAssertEqual(first.uuid, second.uuid)
  }

  func testAddPersistsToUserDefaults() async throws {
    let mock = MockPiholeService()
    mock.addDomainStub = .success(
      DomainEntry(id: 42, domain: "persist.com", type: 0, comment: "uuid-1")
    )

    let provider = MockServerProvider()
    provider.servers = [
      PiholeServer(label: "Main", url: "http://192.168.1.100", version: .v6)
    ]
    provider.makeService = { _ in mock }

    let manager = TempUnblockManager(serverProvider: provider, userDefaults: defaults)
    _ = try await manager.add(domain: "persist.com", duration: 300)

    let manager2 = TempUnblockManager(serverProvider: provider, userDefaults: defaults)
    let count = manager2.activeRecords.count
    let domain = manager2.activeRecords.first?.domain
    let duration = manager2.activeRecords.first?.durationSeconds
    XCTAssertEqual(count, 1)
    XCTAssertEqual(domain, "persist.com")
    XCTAssertEqual(duration, 300)
  }
}
