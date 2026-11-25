import Foundation

@testable import HoleberryCore

/// Configurable mock implementing `StorageLegacyMigrating`, the app-only migration seam.
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
