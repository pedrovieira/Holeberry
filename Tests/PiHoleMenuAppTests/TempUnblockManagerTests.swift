import Defaults
import XCTest
@testable import PiHoleMenuApp

@MainActor
final class TempUnblockManagerTests: XCTestCase {
  override func setUp() {
    super.setUp()
    Defaults[.tempUnblocks] = []
  }

  override func tearDown() {
    Defaults[.tempUnblocks] = []
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

    let manager = TempUnblockManager(serverProvider: provider)
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

    let manager = TempUnblockManager(serverProvider: provider)
    let record = try await manager.add(domain: "doubleclick.net", duration: 300)

    XCTAssertEqual(mock1.addDomainCallCount, 1)
    XCTAssertEqual(mock2.addDomainCallCount, 1)
    XCTAssertEqual(record.domain, "doubleclick.net")
  }

  func testAddWithNoServersThrows() async {
    let provider = MockServerProvider()
    provider.servers = []

    let manager = TempUnblockManager(serverProvider: provider)
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

    let manager = TempUnblockManager(serverProvider: provider)
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

    let manager = TempUnblockManager(serverProvider: provider)
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

    let manager = TempUnblockManager(serverProvider: provider)
    let first = try await manager.add(domain: "doubleclick.net", duration: 300)
    let second = try await manager.add(domain: "doubleclick.net", duration: 300)

    XCTAssertEqual(mock.addDomainCallCount, 1)
    XCTAssertEqual(first.uuid, second.uuid)
  }

  // MARK: - Auto-expiry

  func testAutoExpiryRemovesRecord() async throws {
    let mock = MockPiholeService()
    mock.addDomainStub = .success(
      DomainEntry(id: 42, domain: "test.com", type: 0, comment: "uuid-1")
    )
    mock.deleteDomainByNameStub = .success(())

    let provider = MockServerProvider()
    provider.servers = [
      PiholeServer(label: "Main", url: "http://192.168.1.100", version: .v6)
    ]
    provider.makeService = { _ in mock }

    let manager = TempUnblockManager(serverProvider: provider)
    _ = try await manager.add(domain: "test.com", duration: 0.1)

    XCTAssertEqual(manager.activeRecords.count, 1)
    try await Task.sleep(for: .milliseconds(500))
    XCTAssertTrue(manager.activeRecords.isEmpty)
    XCTAssertEqual(mock.deleteDomainByNameCallCount, 1)
  }

  func testAutoExpiryOnMultipleServers() async throws {
    var callCount = 0
    let mockA = MockPiholeService()
    mockA.addDomainStub = .success(DomainEntry(id: 1, domain: "test.com", type: 0, comment: "uuid-1"))
    mockA.deleteDomainByNameStub = .success(())
    let mockB = MockPiholeService()
    mockB.addDomainStub = .success(DomainEntry(id: 2, domain: "test.com", type: 0, comment: "uuid-1"))
    mockB.deleteDomainByNameStub = .success(())

    let provider = MockServerProvider()
    provider.servers = [
      PiholeServer(label: "A", url: "http://192.168.1.100", version: .v6),
      PiholeServer(label: "B", url: "http://192.168.1.101", version: .v6)
    ]
    provider.makeService = { server in
      server.label == "A" ? mockA : mockB
    }

    let manager = TempUnblockManager(serverProvider: provider)
    _ = try await manager.add(domain: "test.com", duration: 0.1)

    try await Task.sleep(for: .milliseconds(500))
    XCTAssertTrue(manager.activeRecords.isEmpty)
    XCTAssertEqual(mockA.deleteDomainByNameCallCount, 1)
    XCTAssertEqual(mockB.deleteDomainByNameCallCount, 1)
  }

  func testAutoExpiryWithDomainAlreadyAbsent() async throws {
    let mock = MockPiholeService()
    mock.addDomainStub = .success(DomainEntry(id: 42, domain: "test.com", type: 0, comment: "uuid-1"))
    mock.deleteDomainByNameStub = .failure(PiholeError.unknown("Domain not found"))

    let provider = MockServerProvider()
    provider.servers = [
      PiholeServer(label: "Main", url: "http://192.168.1.100", version: .v6)
    ]
    provider.makeService = { _ in mock }

    let manager = TempUnblockManager(serverProvider: provider)
    _ = try await manager.add(domain: "test.com", duration: 0.1)

    try await Task.sleep(for: .milliseconds(500))
    XCTAssertTrue(manager.activeRecords.isEmpty)
  }

  func testAutoExpiryFailureMarksPending() async throws {
    let mock = MockPiholeService()
    mock.addDomainStub = .success(DomainEntry(id: 42, domain: "test.com", type: 0, comment: "uuid-1"))
    mock.deleteDomainByNameStub = .failure(PiholeError.server(500, "Overloaded"))

    let provider = MockServerProvider()
    provider.servers = [
      PiholeServer(label: "Main", url: "http://192.168.1.100", version: .v6)
    ]
    provider.makeService = { _ in mock }

    let manager = TempUnblockManager(serverProvider: provider)
    _ = try await manager.add(domain: "test.com", duration: 0.1)

    try await Task.sleep(for: .milliseconds(500))
    XCTAssertEqual(manager.activeRecords.count, 1)
    XCTAssertTrue(manager.activeRecords[0].pendingRemoval)
    XCTAssertEqual(manager.activeRecords[0].retryCount, 1)
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

    let manager = TempUnblockManager(serverProvider: provider)
    _ = try await manager.add(domain: "persist.com", duration: 300)

    let manager2 = TempUnblockManager(serverProvider: provider)
    let count = manager2.activeRecords.count
    let domain = manager2.activeRecords.first?.domain
    let duration = manager2.activeRecords.first?.durationSeconds
    XCTAssertEqual(count, 1)
    XCTAssertEqual(domain, "persist.com")
    XCTAssertEqual(duration, 300)
  }

  // MARK: - reconcileOnLaunch

  func testReconcileActiveRecordRestored() async throws {
    let mock = MockPiholeService()
    mock.getDomainsStub = .success([
      DomainEntry(id: 42, domain: "active.com", type: 0, comment: "pihole-menu-app:existing-uuid")
    ])

    let provider = MockServerProvider()
    provider.servers = [
      PiholeServer(label: "Main", url: "http://192.168.1.100", version: .v6)
    ]
    provider.makeService = { _ in mock }

    let manager = TempUnblockManager(serverProvider: provider)
    let active = TempUnblockRecord(
      domain: "active.com",
      uuid: "pihole-menu-app:existing-uuid",
      startDateUTC: Date(),
      durationSeconds: 3600
    )
    manager.activeRecords = [active]
    manager.saveRecords()

    let manager2 = TempUnblockManager(serverProvider: provider)
    await manager2.reconcileOnLaunch()

    XCTAssertEqual(manager2.activeRecords.count, 1)
    XCTAssertEqual(manager2.activeRecords[0].domain, "active.com")
  }

  func testReconcileOrphanRemoved() async throws {
    let mock = MockPiholeService()
    mock.getDomainsStub = .success([])

    let provider = MockServerProvider()
    provider.servers = [
      PiholeServer(label: "Main", url: "http://192.168.1.100", version: .v6)
    ]
    provider.makeService = { _ in mock }

    let manager = TempUnblockManager(serverProvider: provider)
    let orphan = TempUnblockRecord(
      domain: "orphan.com",
      uuid: "pihole-menu-app:orphan-uuid",
      startDateUTC: Date(),
      durationSeconds: 3600
    )
    manager.activeRecords = [orphan]
    manager.saveRecords()

    let manager2 = TempUnblockManager(serverProvider: provider)
    await manager2.reconcileOnLaunch()

    XCTAssertTrue(manager2.activeRecords.isEmpty)
  }

  func testReconcileMultipleServersOrphanCheck() async throws {
    let mock1 = MockPiholeService()
    mock1.getDomainsStub = .success([])
    let mock2 = MockPiholeService()
    mock2.getDomainsStub = .success([])

    let provider = MockServerProvider()
    provider.servers = [
      PiholeServer(label: "A", url: "http://192.168.1.100", version: .v6),
      PiholeServer(label: "B", url: "http://192.168.1.101", version: .v6)
    ]
    provider.makeService = { server in
      server.label == "A" ? mock1 : mock2
    }

    let manager = TempUnblockManager(serverProvider: provider)
    let orphan = TempUnblockRecord(
      domain: "orphan.com",
      uuid: "pihole-menu-app:orphan-uuid",
      startDateUTC: Date(),
      durationSeconds: 3600
    )
    manager.activeRecords = [orphan]
    manager.saveRecords()

    let manager2 = TempUnblockManager(serverProvider: provider)
    await manager2.reconcileOnLaunch()

    XCTAssertTrue(manager2.activeRecords.isEmpty)
  }
}
