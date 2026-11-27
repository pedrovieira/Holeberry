import Foundation

@testable import HoleberryCore

/// Configurable app-only migration mock.
@MainActor
final class MockStorageLegacyMigrator: StorageLegacyMigrating {
  var resultStub: Result<StorageLegacyMigrationResult, any Error>?
  private(set) var runIfNeededCallCount = 0

  func runIfNeeded() throws -> StorageLegacyMigrationResult {
    runIfNeededCallCount += 1
    guard let resultStub else { throw MockStorageLegacyMigratorError.notStubbed }
    return try resultStub.get()
  }
}

private enum MockStorageLegacyMigratorError: Error {
  case notStubbed
}
