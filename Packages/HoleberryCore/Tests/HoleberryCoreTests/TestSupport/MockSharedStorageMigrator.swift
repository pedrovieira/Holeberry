import Foundation

@testable import HoleberryCore

/// Configurable mock implementing `SharedStorageMigrating` for unit tests.
@MainActor
final class MockSharedStorageMigrator: SharedStorageMigrating {
  var migrateErrorStub: (any Error)?
  private(set) var migrateCallCount = 0

  func migrate() throws {
    migrateCallCount += 1
    if let migrateErrorStub { throw migrateErrorStub }
  }
}
