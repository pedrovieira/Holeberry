import CoreFoundation
import Darwin
import Foundation

@testable import HoleberryCore

/// A validated, credential-free-rendering description of one prepared Pi-hole lane.
///
/// The credential is stored because the production service needs it, but every
/// string and debug rendering omits it so test failures cannot echo it.
struct IntegrationLane: Sendable {
  let version: ServerVersion
  let url: String
  let credential: String
  let queryStart: Int
  let queryEnd: Int
  let clientIP: String

  var queryInterval: ClosedRange<Int> {
    queryStart...queryEnd
  }
}

extension IntegrationLane: CustomStringConvertible, CustomDebugStringConvertible {
  var description: String {
    "IntegrationLane(\(version.rawValue), url: \(url), queries: \(queryStart)...\(queryEnd), client: \(clientIP))"
  }

  var debugDescription: String {
    description
  }
}

/// Removes registered credentials and their common wire encodings from test text.
///
/// The integration target records failures through this boundary so a production
/// error can never be persisted verbatim in the runner's report.
struct IntegrationRedactor: Sendable {
  private static let replacement = "[REDACTED]"

  private let values: [String]

  init(secrets: [String]) {
    var variants = Set<String>()
    for secret in secrets where !secret.isEmpty {
      variants.insert(secret)
      variants.insert(Self.jsonEscaped(secret))
      variants.insert(Self.xmlEscaped(secret))
      for encoded in Self.percentEncoded(secret) {
        variants.insert(encoded)
      }
    }
    self.values = variants.sorted { $0.count > $1.count }
  }

  func sanitize(_ text: String) -> String {
    var result = text
    for value in values where result.contains(value) {
      result = result.replacingOccurrences(of: value, with: Self.replacement)
    }
    return result
  }

  private static func percentEncoded(_ value: String) -> [String] {
    var unreserved = CharacterSet.alphanumerics
    unreserved.insert(charactersIn: "-._~")
    var queryAllowed = CharacterSet.alphanumerics
    queryAllowed.insert(charactersIn: "-._~=&+")
    return [unreserved, queryAllowed].compactMap { allowed in
      value.addingPercentEncoding(withAllowedCharacters: allowed)
    }
  }

  private static func jsonEscaped(_ value: String) -> String {
    var result = ""
    for scalar in value.unicodeScalars {
      switch scalar {
      case "\\": result += "\\\\"
      case "\"": result += "\\\""
      case "\n": result += "\\n"
      case "\r": result += "\\r"
      case "\t": result += "\\t"
      default:
        if scalar.value < 0x20 {
          result += String(format: "\\u%04x", scalar.value)
        } else {
          result.unicodeScalars.append(scalar)
        }
      }
    }
    return result
  }

  private static func xmlEscaped(_ value: String) -> String {
    value
      .replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
      .replacingOccurrences(of: "\"", with: "&quot;")
      .replacingOccurrences(of: "'", with: "&apos;")
  }
}

/// Safe configuration failures. Every message names a key or field, never a value.
enum IntegrationEnvironmentError: Error, LocalizedError, Equatable {
  case notEnabled
  case missingKeys([String])
  case invalidValue(key: String, reason: String)
  case metadataMissing(path: String)
  case metadataUnreadable(path: String)
  case metadataMalformed(field: String)
  case unsupportedSchema

  var errorDescription: String? {
    switch self {
    case .notEnabled:
      return "HOLEBERRY_INTEGRATION must be exactly 1 to run integration scenarios."
    case .missingKeys(let keys):
      return "Missing required integration configuration: \(keys.joined(separator: ", "))."
    case .invalidValue(let key, let reason):
      return "Invalid integration configuration for \(key): \(reason)."
    case .metadataMissing(let path):
      return "Integration fixture metadata is missing: \(path)."
    case .metadataUnreadable(let path):
      return "Integration fixture metadata is unreadable: \(path)."
    case .metadataMalformed(let field):
      return "Integration fixture metadata is malformed at field \(field)."
    case .unsupportedSchema:
      return "Integration fixture metadata uses an unsupported schema_version."
    }
  }
}

/// Runtime-only validated configuration for the opted-in integration suite.
struct IntegrationEnvironment: Sendable {
  static let optInKey = "HOLEBERRY_INTEGRATION"
  static let v5URLKey = "HOLEBERRY_V5_URL"
  static let v6URLKey = "HOLEBERRY_V6_URL"
  static let v5TokenKey = "HOLEBERRY_V5_TOKEN"
  static let v6PasswordKey = "HOLEBERRY_V6_PASSWORD"
  static let fixturesKey = "HOLEBERRY_INTEGRATION_FIXTURES"
  static let artifactsKey = "HOLEBERRY_INTEGRATION_ARTIFACTS"

  static let requiredKeys = [
    v5URLKey,
    v5TokenKey,
    v6URLKey,
    v6PasswordKey,
    fixturesKey,
    artifactsKey
  ]

  let v5: IntegrationLane
  let v6: IntegrationLane
  let fixturesPath: URL
  let artifactDirectory: URL
  let redactor: IntegrationRedactor

  var lanes: [IntegrationLane] {
    [v5, v6]
  }

  func lane(for version: ServerVersion) -> IntegrationLane {
    switch version {
    case .v5: return v5
    case .v6: return v6
    }
  }

  static func load(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    fileManager: FileManager = .default
  ) throws -> IntegrationEnvironment {
    guard environment[optInKey] == "1" else {
      throw IntegrationEnvironmentError.notEnabled
    }

    let missing = requiredKeys.filter { (environment[$0] ?? "").isEmpty }
    guard missing.isEmpty else {
      throw IntegrationEnvironmentError.missingKeys(missing)
    }

    guard
      let v5URLValue = environment[v5URLKey],
      let v6URLValue = environment[v6URLKey],
      let v5CredentialValue = environment[v5TokenKey],
      let v6CredentialValue = environment[v6PasswordKey],
      let fixturesValue = environment[fixturesKey],
      let artifactsValue = environment[artifactsKey]
    else {
      throw IntegrationEnvironmentError.missingKeys(requiredKeys)
    }

    let v5URL = try validatedLoopbackURL(v5URLValue, key: v5URLKey)
    let v6URL = try validatedLoopbackURL(v6URLValue, key: v6URLKey)
    let v5Credential = try validatedCredential(v5CredentialValue, key: v5TokenKey)
    let v6Credential = try validatedCredential(v6CredentialValue, key: v6PasswordKey)
    let fixturesPath = try validatedFixturesPath(fixturesValue, fileManager: fileManager)
    let artifactDirectory = try validatedArtifactDirectory(
      artifactsValue,
      fileManager: fileManager
    )

    let data: Data
    do {
      data = try Data(contentsOf: fixturesPath)
    } catch {
      throw IntegrationEnvironmentError.metadataUnreadable(path: fixturesPath.path)
    }

    let root = try metadataRoot(from: data)
    guard let schema = integerValue(root["schema_version"]) else {
      throw IntegrationEnvironmentError.metadataMalformed(field: "schema_version")
    }
    guard schema == 1 else {
      throw IntegrationEnvironmentError.unsupportedSchema
    }
    guard let lanesObject = root["lanes"] as? [String: Any] else {
      throw IntegrationEnvironmentError.metadataMalformed(field: "lanes")
    }
    guard Set(lanesObject.keys) == ["v5", "v6"] else {
      throw IntegrationEnvironmentError.metadataMalformed(field: "lanes")
    }

    let v5Metadata = try validatedLaneMetadata(lanesObject["v5"], lane: "v5")
    let v6Metadata = try validatedLaneMetadata(lanesObject["v6"], lane: "v6")

    guard normalizedURLString(v5Metadata.url) == normalizedURLString(v5URL) else {
      throw IntegrationEnvironmentError.invalidValue(
        key: v5URLKey,
        reason: "does not match the prepared fixture metadata"
      )
    }
    guard normalizedURLString(v6Metadata.url) == normalizedURLString(v6URL) else {
      throw IntegrationEnvironmentError.invalidValue(
        key: v6URLKey,
        reason: "does not match the prepared fixture metadata"
      )
    }

    let v5Lane = IntegrationLane(
      version: .v5,
      url: v5URL.absoluteString,
      credential: v5Credential,
      queryStart: v5Metadata.queryStart,
      queryEnd: v5Metadata.queryEnd,
      clientIP: v5Metadata.clientIP
    )
    let v6Lane = IntegrationLane(
      version: .v6,
      url: v6URL.absoluteString,
      credential: v6Credential,
      queryStart: v6Metadata.queryStart,
      queryEnd: v6Metadata.queryEnd,
      clientIP: v6Metadata.clientIP
    )

    return IntegrationEnvironment(
      v5: v5Lane,
      v6: v6Lane,
      fixturesPath: fixturesPath,
      artifactDirectory: artifactDirectory,
      redactor: IntegrationRedactor(secrets: [v5Credential, v6Credential])
    )
  }

  // MARK: - Validation

  private struct LaneMetadata {
    let url: URL
    let queryStart: Int
    let queryEnd: Int
    let clientIP: String
  }

  private static func metadataRoot(from data: Data) throws -> [String: Any] {
    let object: Any
    do {
      object = try JSONSerialization.jsonObject(with: data, options: [])
    } catch {
      throw IntegrationEnvironmentError.metadataMalformed(field: "root")
    }
    guard let root = object as? [String: Any] else {
      throw IntegrationEnvironmentError.metadataMalformed(field: "root")
    }
    return root
  }

  private static func validatedLaneMetadata(_ value: Any?, lane: String) throws -> LaneMetadata {
    guard let object = value as? [String: Any] else {
      throw IntegrationEnvironmentError.metadataMalformed(field: "lanes.\(lane)")
    }
    guard let urlValue = object["url"] as? String else {
      throw IntegrationEnvironmentError.metadataMalformed(field: "lanes.\(lane).url")
    }
    let url = try validatedLoopbackURL(urlValue, key: "lanes.\(lane).url")
    guard
      let queryStart = integerValue(object["query_start"]),
      let queryEnd = integerValue(object["query_end"])
    else {
      throw IntegrationEnvironmentError.metadataMalformed(
        field: "lanes.\(lane).query_interval"
      )
    }
    guard queryStart < queryEnd else {
      throw IntegrationEnvironmentError.metadataMalformed(
        field: "lanes.\(lane).query_interval"
      )
    }
    guard let clientIP = object["client_ip"] as? String, isNumericIP(clientIP) else {
      throw IntegrationEnvironmentError.metadataMalformed(
        field: "lanes.\(lane).client_ip"
      )
    }
    return LaneMetadata(
      url: url,
      queryStart: queryStart,
      queryEnd: queryEnd,
      clientIP: clientIP
    )
  }

  private static func validatedLoopbackURL(_ raw: String, key: String) throws -> URL {
    guard
      let components = URLComponents(string: raw),
      let scheme = components.scheme?.lowercased()
    else {
      throw IntegrationEnvironmentError.invalidValue(
        key: key,
        reason: "must be an absolute HTTP URL"
      )
    }
    guard scheme == "http" else {
      throw IntegrationEnvironmentError.invalidValue(key: key, reason: "must use HTTP")
    }
    guard components.user == nil, components.password == nil else {
      throw IntegrationEnvironmentError.invalidValue(
        key: key,
        reason: "must not contain user information"
      )
    }
    guard components.query == nil, components.fragment == nil else {
      throw IntegrationEnvironmentError.invalidValue(
        key: key,
        reason: "must not contain a query or fragment"
      )
    }
    guard let host = components.host, isLoopbackHost(host) else {
      throw IntegrationEnvironmentError.invalidValue(
        key: key,
        reason: "must target a loopback host"
      )
    }
    guard components.path.isEmpty || components.path == "/" else {
      throw IntegrationEnvironmentError.invalidValue(
        key: key,
        reason: "must not contain a path"
      )
    }
    guard let url = components.url else {
      throw IntegrationEnvironmentError.invalidValue(key: key, reason: "must be a valid URL")
    }
    return url
  }

  private static func validatedCredential(_ raw: String, key: String) throws -> String {
    guard !raw.isEmpty else {
      throw IntegrationEnvironmentError.invalidValue(key: key, reason: "must not be empty")
    }
    guard !raw.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\0" }) else {
      throw IntegrationEnvironmentError.invalidValue(
        key: key,
        reason: "must be a single-line value"
      )
    }
    return raw
  }

  private static func validatedFixturesPath(
    _ raw: String,
    fileManager: FileManager
  ) throws -> URL {
    guard raw.hasPrefix("/") else {
      throw IntegrationEnvironmentError.invalidValue(
        key: fixturesKey,
        reason: "must be an absolute path"
      )
    }
    let path = URL(fileURLWithPath: raw, isDirectory: false)
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: path.path, isDirectory: &isDirectory) else {
      throw IntegrationEnvironmentError.metadataMissing(path: path.path)
    }
    guard !isDirectory.boolValue else {
      throw IntegrationEnvironmentError.metadataMalformed(field: "HOLEBERRY_INTEGRATION_FIXTURES")
    }
    return path
  }

  private static func validatedArtifactDirectory(
    _ raw: String,
    fileManager: FileManager
  ) throws -> URL {
    guard raw.hasPrefix("/") else {
      throw IntegrationEnvironmentError.invalidValue(
        key: artifactsKey,
        reason: "must be an absolute path"
      )
    }
    let url = URL(fileURLWithPath: raw, isDirectory: true)
    var isDirectory: ObjCBool = false
    guard
      fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
      isDirectory.boolValue,
      fileManager.isWritableFile(atPath: url.path)
    else {
      throw IntegrationEnvironmentError.invalidValue(
        key: artifactsKey,
        reason: "must name an existing writable directory"
      )
    }
    return url
  }

  private static func integerValue(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber else { return nil }
    guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
    let double = number.doubleValue
    guard double.isFinite, double.rounded() == double else { return nil }
    guard double >= Double(Int.min), double <= Double(Int.max) else { return nil }
    return Int(double)
  }

  private static func isNumericIP(_ value: String) -> Bool {
    var ipv4 = in_addr()
    if inet_pton(AF_INET, value, &ipv4) == 1 {
      return true
    }
    var ipv6 = in6_addr()
    return inet_pton(AF_INET6, value, &ipv6) == 1
  }

  private static func isLoopbackHost(_ host: String) -> Bool {
    if host.caseInsensitiveCompare("localhost") == .orderedSame {
      return true
    }
    var ipv4 = in_addr()
    if inet_pton(AF_INET, host, &ipv4) == 1 {
      return UInt32(bigEndian: ipv4.s_addr) >> 24 == 127
    }
    var ipv6 = in6_addr()
    guard inet_pton(AF_INET6, host, &ipv6) == 1 else {
      return false
    }
    var loopback = in6_addr()
    guard "::1".withCString({ inet_pton(AF_INET6, $0, &loopback) }) == 1 else {
      return false
    }
    return withUnsafeBytes(of: ipv6) { candidate in
      withUnsafeBytes(of: loopback) { expected in
        candidate.elementsEqual(expected)
      }
    }
  }

  private static func normalizedURLString(_ url: URL) -> String {
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      return url.absoluteString
    }
    components.scheme = components.scheme?.lowercased()
    components.host = components.host?.lowercased()
    if components.path == "/" {
      components.path = ""
    }
    return components.url?.absoluteString ?? url.absoluteString
  }
}

extension IntegrationEnvironment: CustomStringConvertible, CustomDebugStringConvertible {
  var description: String {
    "IntegrationEnvironment(v5: \(v5), v6: \(v6), fixtures: \(fixturesPath.path), "
      + "artifacts: \(artifactDirectory.path))"
  }

  var debugDescription: String {
    description
  }
}
