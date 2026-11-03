import Foundation

@testable import HoleberryCore

/// One disposable Pi-hole lane.
enum IntegrationTarget: String, CaseIterable, Sendable {
  case v5
  case v6
  case v6Open = "v6-open"

  var version: ServerVersion {
    self == .v5 ? .v5 : .v6
  }

  var container: ContainerService {
    switch self {
    case .v5:
      return .v5
    case .v6:
      return .v6
    case .v6Open:
      return .v6Open
    }
  }

  var isPasswordless: Bool {
    self == .v6Open
  }
}

enum IntegrationEnvironmentError: Error, LocalizedError, Equatable {
  case invalidURLOverride(key: String, value: String)

  var errorDescription: String? {
    switch self {
    case .invalidURLOverride(let key, let value):
      return "\(key) must be an absolute HTTP or HTTPS URL with a host; got '\(value)'."
    }
  }
}

/// Local container settings shared by the integration suite.
///
/// The suite is opt-in: a plain `swift test` compiles this target and skips it.
enum IntegrationEnvironment {
  static let optInKey = "HOLEBERRY_INTEGRATION"
  static let v5BaseURL = URL(string: "http://127.0.0.1:18085")!
  static let v6BaseURL = URL(string: "http://127.0.0.1:18086")!
  static let v6OpenBaseURL = URL(string: "http://127.0.0.1:18087")!
  static let v6Password = "holeberry-integration"

  static var isEnabled: Bool {
    ProcessInfo.processInfo.environment[optInKey] == "1"
  }

  static func baseURL(
    for target: IntegrationTarget,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) throws -> URL {
    let key: String
    let fallback: URL
    switch target {
    case .v5:
      key = "HOLEBERRY_V5_URL"
      fallback = v5BaseURL
    case .v6:
      key = "HOLEBERRY_V6_URL"
      fallback = v6BaseURL
    case .v6Open:
      key = "HOLEBERRY_V6_OPEN_URL"
      fallback = v6OpenBaseURL
    }

    guard let raw = environment[key] else {
      return fallback
    }
    guard let url = URL(string: raw),
      let scheme = url.scheme?.lowercased(),
      ["http", "https"].contains(scheme),
      let host = url.host, !host.isEmpty
    else {
      throw IntegrationEnvironmentError.invalidURLOverride(key: key, value: raw)
    }
    return url
  }

  /// `Containers/compose.yml`, resolved from this support file's location.
  static var composeFile: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // Support
      .deletingLastPathComponent()  // HoleberryCoreIntegrationTests
      .appendingPathComponent("Containers/compose.yml")
  }
}
