import Compression
import Foundation
import OSLog

final class GeckoSessionStoreUrlFetchingStrategy: BrowserActiveUrlFetchingStrategy {
  private let logger: Logger
  private let supportDir: URL

  init(supportDirName: String, category: String) {
    let home = FileManager.default.homeDirectoryForCurrentUser
    self.supportDir = home.appendingPathComponent("Library/Application Support/\(supportDirName)")
    self.logger = Logger(subsystem: Logger.appSubsystem, category: category)
  }

  func getCurrentURL(for browser: Browser) -> String? {
    let profilesINI = supportDir.appendingPathComponent("profiles.ini")
    guard let profilePath = resolveDefaultProfilePath(from: profilesINI) else {
      logger.warning("Could not resolve default profile from profiles.ini")
      return nil
    }

    // Try sessionstore.jsonlz4 first, then recovery.jsonlz4
    let sessionStoreURL = profilePath.appendingPathComponent("sessionstore.jsonlz4")
    if let compressedData = try? Data(contentsOf: sessionStoreURL) {
      return extractURL(from: compressedData)
    }

    let recoveryURL = profilePath.appendingPathComponent("sessionstore-backups/recovery.jsonlz4")
    if let compressedData = try? Data(contentsOf: recoveryURL) {
      return extractURL(from: compressedData)
    }

    // Retry sessionstore.jsonlz4 once after 100ms in case file was being written
    Thread.sleep(forTimeInterval: 0.1)
    if let compressedData = try? Data(contentsOf: sessionStoreURL) {
      return extractURL(from: compressedData)
    }

    logger.warning("Sessionstore not found at \(profilePath.path)")
    return nil
  }

  // MARK: - Permission

  func isPermissionGranted(for browser: Browser) -> AutomationPermission {
    .allowed  // Gecko-based browsers read session files, no Apple Events needed
  }

  func requestPermission(for browser: Browser) {
    // No-op: Gecko-based browsers don't use Apple Events
  }

  // MARK: - profiles.ini parsing

  private func resolveDefaultProfilePath(from iniURL: URL) -> URL? {
    guard let content = try? String(contentsOf: iniURL, encoding: .utf8) else { return nil }

    // Prefer [Install*] with Locked=1 (the actually active profile)
    if let path = Self.resolveProfileFromInstallSection(in: content, supportDir: supportDir) {
      return path
    }

    // Fall back to [Profile*] with Default=1
    return Self.resolveProfileFromProfileSection(in: content, supportDir: supportDir)
  }

  /// Extracts the active profile path from `profiles.ini` content, looking for `[Install*]` with `Locked=1`.
  static func resolveProfileFromInstallSection(in content: String, supportDir: URL) -> URL? {
    var inSection = false
    var path: String?
    var locked = false

    for line in content.components(separatedBy: .newlines) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
        if inSection, locked, let resolved = path {
          return resolvePath(resolved, isRelative: true, supportDir: supportDir)
        }
        inSection = trimmed.hasPrefix("[Install")
        path = nil
        locked = false
      } else if inSection, trimmed.hasPrefix("Default=") {
        path = String(trimmed.dropFirst("Default=".count))
      } else if inSection, trimmed.hasPrefix("Locked=") {
        let value = String(trimmed.dropFirst("Locked=".count))
        locked = (Int(value) ?? 0) == 1
      }
    }

    if inSection, locked, let resolved = path {
      return resolvePath(resolved, isRelative: true, supportDir: supportDir)
    }
    return nil
  }

  /// Extracts the default profile path from `profiles.ini` content, looking for `[Profile*]` with `Default=1`.
  static func resolveProfileFromProfileSection(in content: String, supportDir: URL) -> URL? {
    var pathValue: String?
    var isRelative: Bool?
    var foundDefault = false

    for line in content.components(separatedBy: .newlines) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
        if foundDefault, let path = pathValue {
          return resolvePath(path, isRelative: isRelative ?? true, supportDir: supportDir)
        }
        pathValue = nil
        isRelative = nil
        foundDefault = false
      } else if trimmed.hasPrefix("Default=") {
        let value = String(trimmed.dropFirst("Default=".count))
        if value == "1" { foundDefault = true }
      } else if trimmed.hasPrefix("Path=") {
        pathValue = String(trimmed.dropFirst("Path=".count))
      } else if trimmed.hasPrefix("IsRelative=") {
        let value = String(trimmed.dropFirst("IsRelative=".count))
        isRelative = (Int(value) ?? 1) == 1
      }
    }

    if foundDefault, let path = pathValue {
      return resolvePath(path, isRelative: isRelative ?? true, supportDir: supportDir)
    }
    return nil
  }

  /// Resolves a profile path from `profiles.ini` content, sanitizing it against path traversal.
  ///
  /// Gecko browsers support both relative (`IsRelative=1`) and absolute (`IsRelative=0`)
  /// profile paths, so both are kept. `profiles.ini` is user-writable, so `.` and `..`
  /// components are resolved lexically here instead of being passed to Foundation path
  /// APIs: a relative path that would escape `supportDir` is rejected, while absolute
  /// paths are normalized against the filesystem root. The URL is built only from the
  /// resolved, in-bounds components.
  static func resolvePath(_ path: String, isRelative: Bool, supportDir: URL) -> URL? {
    let rawComponents = path.split(separator: "/").map(String.init)
    guard !rawComponents.isEmpty else { return nil }

    let isAbsolute = path.hasPrefix("/")
    guard isRelative || isAbsolute else { return nil }

    let base: URL = isAbsolute ? URL(fileURLWithPath: "/") : supportDir.standardizedFileURL
    var components: [String] = []
    for component in rawComponents {
      if component == "." {
        continue
      }
      if component == ".." {
        if !components.isEmpty {
          components.removeLast()
          continue
        }
        // Nothing left to pop: on relative paths this escapes `supportDir`; on
        // absolute paths `..` at the root is a no-op.
        guard isAbsolute else { return nil }
        continue
      }
      components.append(component)
    }

    return components.reduce(base) { $0.appendingPathComponent($1) }
  }

  // MARK: - mozLZ4 decompression

  /// Decompresses and parses a Firefox sessionstore file (mozLZ4 format) to extract the current tab's URL.
  /// - Parameter compressedData: Raw file data with mozLz40 header.
  /// - Returns: The URL string of the active tab, or `nil` if parsing fails.
  static func extractURL(from compressedData: Data) -> String? {
    // mozLZ4 header: 8 bytes magic "mozLz40\0" + 4 bytes uint32 LE uncompressed size = 12 bytes total
    guard compressedData.count > 12 else {
      return nil
    }

    let magic = compressedData.prefix(8)
    guard magic == Data("mozLz40\0".utf8) else {
      return nil
    }

    let uncompressedSize = compressedData.subdata(in: 8..<12).withUnsafeBytes { $0.load(as: UInt32.self) }
    let compressedPayload = compressedData.dropFirst(12)

    // Decompress using Apple's Compression framework (LZ4 raw block format)
    let destinationBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(uncompressedSize))
    defer { destinationBuffer.deallocate() }

    let actualSize = compressedPayload.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
      guard let srcBase = src.baseAddress else { return 0 }
      return compression_decode_buffer(
        destinationBuffer,
        Int(uncompressedSize),
        srcBase,
        compressedPayload.count,
        nil,
        COMPRESSION_LZ4_RAW
      )
    }

    guard actualSize > 0, actualSize == Int(uncompressedSize) else {
      return nil
    }

    // Parse JSON (1-based indexing for selectedWindow and tab selected)
    let decompressedData = Data(bytes: destinationBuffer, count: actualSize)
    guard let json = try? JSONSerialization.jsonObject(with: decompressedData) as? [String: Any],
      let windows = json["windows"] as? [[String: Any]],
      let selectedIndex = json["selectedWindow"] as? Int,
      selectedIndex > 0,
      selectedIndex <= windows.count
    else {
      return nil
    }

    let window = windows[selectedIndex - 1]
    guard let tabs = window["tabs"] as? [[String: Any]],
      let selectedTabIndex = window["selected"] as? Int,
      selectedTabIndex > 0,
      selectedTabIndex <= tabs.count
    else {
      return nil
    }

    let tab = tabs[selectedTabIndex - 1]
    guard let entries = tab["entries"] as? [[String: Any]] else {
      return nil
    }
    let activeIndex = (tab["index"] as? Int) ?? 1
    guard activeIndex > 0, activeIndex <= entries.count else {
      return nil
    }

    let entry = entries[activeIndex - 1]
    return entry["url"] as? String
  }

  /// Instance wrapper around the static `extractURL(from:)` for internal use.
  private func extractURL(from compressedData: Data) -> String? {
    Self.extractURL(from: compressedData)
  }
}
