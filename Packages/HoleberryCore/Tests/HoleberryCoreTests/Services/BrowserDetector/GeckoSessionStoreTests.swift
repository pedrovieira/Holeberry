import Foundation
import Testing

@testable import HoleberryCore


// MARK: - GeckoSessionStoreUrlFetchingStrategy - profiles.ini parsing

@Suite("GeckoSessionStore URL fetching")
struct GeckoSessionStoreTests {
  private let supportDir = URL(fileURLWithPath: "/Users/test/Library/Application Support/Firefox")

  // MARK: - profiles.ini: Install section

  @Test("resolves Install section with Locked=1")
  func installSectionLocked() {
    let ini = """
      [Install404C0A7C0A7C404C]
      Default=profiles.ini
      Locked=1
      """
    let path = GeckoSessionStoreUrlFetchingStrategy.resolveProfileFromInstallSection(in: ini, supportDir: supportDir)
    #expect(path != nil)
    #expect(path?.path == "/Users/test/Library/Application Support/Firefox/profiles.ini")
  }

  @Test("ignores Install section without Locked=1")
  func installSectionNotLocked() {
    let ini = """
      [Install404C0A7C0A7C404C]
      Default=profiles.ini
      Locked=0
      """
    let path = GeckoSessionStoreUrlFetchingStrategy.resolveProfileFromInstallSection(in: ini, supportDir: supportDir)
    #expect(path == nil)
  }

  @Test("ignores non-Install sections while scanning")
  func installSectionSkipsNonInstall() {
    let ini = """
      [General]
      StartWithLastProfile=1
      [Install404C0A7C0A7C404C]
      Default=test-profile
      Locked=1
      """
    let path = GeckoSessionStoreUrlFetchingStrategy.resolveProfileFromInstallSection(in: ini, supportDir: supportDir)
    #expect(path?.path == "/Users/test/Library/Application Support/Firefox/test-profile")
  }

  // MARK: - profiles.ini: Profile section

  @Test("resolves Profile section with Default=1")
  func profileSectionDefault() {
    let ini = """
      [Profile0]
      Name=default
      Path=Profiles/abcdef.default
      Default=1
      IsRelative=1
      """
    let path = GeckoSessionStoreUrlFetchingStrategy.resolveProfileFromProfileSection(in: ini, supportDir: supportDir)
    #expect(path != nil)
    #expect(path?.path == "/Users/test/Library/Application Support/Firefox/Profiles/abcdef.default")
  }

  @Test("skips non-default profiles")
  func profileSectionNonDefault() {
    let ini = """
      [Profile0]
      Name=dev
      Path=Profiles/dev-profile
      Default=0
      IsRelative=1

      [Profile1]
      Name=default
      Path=Profiles/abcdef.default
      Default=1
      IsRelative=1
      """
    let path = GeckoSessionStoreUrlFetchingStrategy.resolveProfileFromProfileSection(in: ini, supportDir: supportDir)
    guard let pathStr = path?.path else {
      Issue.record("Expected non-nil path")
      return
    }
    #expect(pathStr.contains("abcdef.default"))
  }

  @Test("resolves absolute path when IsRelative=0")
  func profileSectionAbsolute() {
    let ini = """
      [Profile0]
      Name=custom
      Path=/Users/custom/Library/Firefox/Profiles/custom
      Default=1
      IsRelative=0
      """
    let path = GeckoSessionStoreUrlFetchingStrategy.resolveProfileFromProfileSection(in: ini, supportDir: supportDir)
    #expect(path != nil)
    #expect(path?.path == "/Users/custom/Library/Firefox/Profiles/custom")
  }

  @Test("returns nil when no default profile")
  func profileSectionNoDefault() {
    let ini = """
      [Profile0]
      Name=dev
      Path=Profiles/dev
      Default=0
      IsRelative=1
      """
    let path = GeckoSessionStoreUrlFetchingStrategy.resolveProfileFromProfileSection(in: ini, supportDir: supportDir)
    #expect(path == nil)
  }

  @Test("returns nil for empty content")
  func emptyContent() {
    let path = GeckoSessionStoreUrlFetchingStrategy.resolveProfileFromInstallSection(in: "", supportDir: supportDir)
    #expect(path == nil)
  }

  // MARK: - resolvePath

  @Test("resolvePath relative appends to supportDir")
  func resolvePathRelative() {
    let url = GeckoSessionStoreUrlFetchingStrategy.resolvePath(
      "Profiles/test", isRelative: true, supportDir: supportDir)
    #expect(url.path == "/Users/test/Library/Application Support/Firefox/Profiles/test")
  }

  @Test("resolvePath absolute returns as-is")
  func resolvePathAbsolute() {
    let url = GeckoSessionStoreUrlFetchingStrategy.resolvePath(
      "/custom/path", isRelative: false, supportDir: supportDir)
    #expect(url.path == "/custom/path")
  }

  // MARK: - mozLZ4 / extractURL

  @Test("extractURL returns nil for data smaller than header")
  func extractURLTooSmall() {
    let data = Data([0x6d, 0x6f, 0x7a, 0x4c])  // "mozL" only
    let url = GeckoSessionStoreUrlFetchingStrategy.extractURL(from: data)
    #expect(url == nil)
  }

  @Test("extractURL returns nil for invalid magic bytes")
  func extractURLInvalidMagic() {
    var data = Data(repeating: 0, count: 13)
    data[0] = 0x00  // wrong magic
    let url = GeckoSessionStoreUrlFetchingStrategy.extractURL(from: data)
    #expect(url == nil)
  }

  @Test("extractURL returns nil for corrupted compressed data")
  func extractURLCorrupted() {
    var data = Data("mozLz40\0".utf8)
    // Uncompressed size = 100 bytes (little-endian)
    data.append(contentsOf: [100, 0, 0, 0])
    // Corrupted payload
    data.append(contentsOf: [0x01, 0x02, 0x03])
    let url = GeckoSessionStoreUrlFetchingStrategy.extractURL(from: data)
    #expect(url == nil)
  }
}
