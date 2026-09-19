import Compression
import Foundation
import OSLog

final class GeckoSessionStoreUrlFetchingStrategy: BrowserActiveUrlFetchingStrategy {
  /// The result of probing the browser's support directory.
  enum SupportDirectoryAccess: Equatable {
    case readable
    case denied
    case unavailable
  }

  let browser: Browser
  private let logger: Logger
  private let supportDir: URL
  private let listDirectory: DirectoryListing

  /// Directory listing, injected so tests can drive the probe with synthetic errors.
  typealias DirectoryListing = (String) throws -> [String]

  init(
    browser: Browser,
    supportDirName: String,
    category: String,
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
    listDirectory: @escaping DirectoryListing = { try FileManager.default.contentsOfDirectory(atPath: $0) }
  ) {
    self.browser = browser
    self.supportDir = homeDirectory.appendingPathComponent("Library/Application Support/\(supportDirName)")
    self.logger = Logger(subsystem: Logger.appSubsystem, category: category)
    self.listDirectory = listDirectory
  }

  func getCurrentURL() -> URL? {
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

  func accessState() -> BrowserAccessState {
    switch checkSupportDirectoryAccess() {
    case .readable:
      return .allowed
    case .denied:
      logger.notice("System denied access to \(self.supportDir.path, privacy: .public)")
      return .denied(.filesAndFolders)
    case .unavailable:
      // Not installed or never launched — treated as "no permission problem".
      return .allowed
    }
  }

  /// Intentionally empty: macOS has no consent dialog for Gecko folder access,
  /// so `accessState()` never reports `.notDetermined` and a denial is only
  /// fixable in System Settings → Files & Folders.
  func requestAccess() {}

  /// Probes the support directory. macOS 27+ app-data protection fails the read
  /// with `NSFileReadNoPermissionError`.
  private func checkSupportDirectoryAccess() -> SupportDirectoryAccess {
    do {
      _ = try listDirectory(supportDir.path)
      return .readable
    } catch {
      return Self.isPermissionError(error) ? .denied : .unavailable
    }
  }

  /// Whether an error is a POSIX-level permission failure rather than, say,
  /// a missing file. Permission errors come from the OS policy, not from the
  /// browser's own state, so the user can fix them in System Settings.
  private static func isPermissionError(_ error: any Error) -> Bool {
    let nsError = error as NSError
    if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileReadNoPermissionError {
      return true
    }
    if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(EPERM) || nsError.code == Int(EACCES) {
      return true
    }
    if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
      return isPermissionError(underlying)
    }
    return false
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

  /// Instance wrapper around the static `extractURL(from:)`, parsed into a URL.
  private func extractURL(from compressedData: Data) -> URL? {
    Self.extractURL(from: compressedData).flatMap { URL(string: $0) }
  }
}
