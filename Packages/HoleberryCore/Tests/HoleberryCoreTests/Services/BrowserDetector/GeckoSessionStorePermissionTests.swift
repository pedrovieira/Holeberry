import Foundation
import Testing

@testable import HoleberryCore

@Suite("GeckoSessionStore permission probe")
struct GeckoSessionStorePermissionTests {
  // MARK: - Error classification

  @Test("treats NSFileReadNoPermissionError wrapping EPERM as a denial")
  func cocoaPermissionError() {
    let underlying = NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))
    let error = NSError(
      domain: NSCocoaErrorDomain,
      code: NSFileReadNoPermissionError,
      userInfo: [NSUnderlyingErrorKey: underlying]
    )
    #expect(strategy(throwing: error).accessState() == .denied(.filesAndFolders))
  }

  @Test("treats a bare POSIX EPERM as a denial")
  func barePOSIXPermissionError() {
    let error = NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))
    #expect(strategy(throwing: error).accessState() == .denied(.filesAndFolders))
  }

  @Test("treats POSIX EACCES as a denial")
  func posixAccessError() {
    let error = NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
    #expect(strategy(throwing: error).accessState() == .denied(.filesAndFolders))
  }

  @Test("does not treat a missing file as a denial")
  func missingFileError() {
    let underlying = NSError(domain: NSOSStatusErrorDomain, code: -43)
    let error = NSError(
      domain: NSCocoaErrorDomain,
      code: NSFileNoSuchFileError,
      userInfo: [NSUnderlyingErrorKey: underlying]
    )
    #expect(strategy(throwing: error).accessState() == .allowed)
  }

  @Test("does not treat unrelated errors as denials")
  func unrelatedError() {
    let error = NSError(domain: "test", code: 1)
    #expect(strategy(throwing: error).accessState() == .allowed)
  }

  // MARK: - Probe

  @Test("a readable support directory is allowed")
  func readableDirectory() throws {
    let home = try makeTemporaryHome(name: "readable")
    defer { try? FileManager.default.removeItem(at: home) }
    try FileManager.default.createDirectory(at: supportDirURL(home: home), withIntermediateDirectories: true)

    let strategy = GeckoSessionStoreUrlFetchingStrategy(
      browser: .firefox,
      supportDirName: "Firefox",
      category: "test",
      homeDirectory: home
    )
    #expect(strategy.accessState() == .allowed)
  }

  @Test("a missing support directory keeps the legacy behavior")
  func missingDirectory() throws {
    let home = try makeTemporaryHome(name: "missing")
    defer { try? FileManager.default.removeItem(at: home) }

    let strategy = GeckoSessionStoreUrlFetchingStrategy(
      browser: .firefox,
      supportDirName: "Firefox",
      category: "test",
      homeDirectory: home
    )
    #expect(strategy.accessState() == .allowed)
  }

  @Test("an unreadable support directory is denied")
  func unreadableDirectory() throws {
    // Root bypasses POSIX permissions, so the probe would see the directory as readable.
    guard getuid() != 0 else { return }

    let fileManager = FileManager.default
    let home = try makeTemporaryHome(name: "unreadable")
    let supportDir = supportDirURL(home: home)
    defer {
      try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: supportDir.path)
      try? fileManager.removeItem(at: home)
    }
    try fileManager.createDirectory(at: supportDir, withIntermediateDirectories: true)
    try fileManager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: supportDir.path)

    let strategy = GeckoSessionStoreUrlFetchingStrategy(
      browser: .firefox,
      supportDirName: "Firefox",
      category: "test",
      homeDirectory: home
    )
    #expect(strategy.accessState() == .denied(.filesAndFolders))
  }

  // MARK: - Helpers

  /// A strategy whose directory probe always fails with `error`.
  private func strategy(throwing error: any Error) -> GeckoSessionStoreUrlFetchingStrategy {
    GeckoSessionStoreUrlFetchingStrategy(
      browser: .firefox,
      supportDirName: "Firefox",
      category: "test",
      listDirectory: { _ in throw error }
    )
  }

  private func makeTemporaryHome(name: String) throws -> URL {
    let home = FileManager.default.temporaryDirectory
      .appendingPathComponent("HoleberryGeckoProbe-\(name)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    return home
  }

  private func supportDirURL(home: URL) -> URL {
    home.appendingPathComponent("Library/Application Support/Firefox")
  }
}
