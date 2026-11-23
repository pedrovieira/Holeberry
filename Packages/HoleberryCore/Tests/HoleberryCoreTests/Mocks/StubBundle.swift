import Foundation

/// A bundle whose Info.plist metadata and read count the test controls.
///
/// `Bundle` caches instances by path, so each stub needs its own empty directory:
/// a shared path would return the first stub created and ignore later fixtures.
/// `Bundle` also only declares failable designated initializers, so construction
/// goes through `#require` in tests.
final class StubBundle: Bundle, @unchecked Sendable {
  nonisolated(unsafe) var fixture: [String: Any]
  nonisolated(unsafe) private(set) var infoReadCount = 0

  init?(fixture: [String: Any] = [:]) {
    self.fixture = fixture
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("HoleberryStubBundle-\(UUID().uuidString)", isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    } catch {
      return nil
    }
    super.init(path: directory.path)
  }

  override var infoDictionary: [String: Any]? {
    infoReadCount += 1
    return fixture
  }
}
