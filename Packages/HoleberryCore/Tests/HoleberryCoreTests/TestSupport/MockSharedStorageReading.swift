import Foundation

@testable import HoleberryCore

/// Configurable mock implementing `SharedStorageReading`, the seam a read-only
/// client takes instead of a writable connection store.
///
/// Without a stub, an open reports that no copy is published. A `MockConnectionStore`
/// serves both reader stubs, because it refines `ServerReading` and `ConnectionReading`.
@MainActor
final class MockSharedStorageReading: SharedStorageReading {
  var serverReaderStub: Result<any ServerReading, any Error>?
  var connectionReaderStub: Result<any ConnectionReading, any Error>?

  private(set) var openServerReaderCallCount = 0
  private(set) var openConnectionReaderCallCount = 0

  func openServerReader() throws -> any ServerReading {
    openServerReaderCallCount += 1
    guard let serverReaderStub else { throw SharedStorageAccessError.copyNotPublished }
    return try serverReaderStub.get()
  }

  func openConnectionReader() throws -> any ConnectionReading {
    openConnectionReaderCallCount += 1
    guard let connectionReaderStub else { throw SharedStorageAccessError.copyNotPublished }
    return try connectionReaderStub.get()
  }
}
