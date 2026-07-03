import Foundation
import OSLog

/// Probes an unauthenticated Pi-hole endpoint to detect v5 vs v6 without knowing the credential.
///
/// `GET /admin/api.php?version` returns two mutually exclusive responses:
///   - **v5:** HTTP 200 with `{"version": ...}`
///   - **v6:**  HTTP 400 with `{"hint": "...the API is hosted at /api..."}`
///
/// Any other response is treated as unreachable.
struct PiholeVersionDetector {
  private static let versionKey = "version"
  private static let hintKey = "hint"
  private static let errorKey = "error"

  static let shared = PiholeVersionDetector()

  private let logger = Logger(
    subsystem: Logger.appSubsystem,
    category: "version-detector"
  )

  private let versionQueryItem = URLQueryItem(name: "version", value: nil)

  private func hint(from json: [String: Any]) -> String? {
    let errorDict = json[Self.errorKey] as? [String: Any]
    return (json[Self.hintKey] as? String) ?? errorDict?[Self.hintKey] as? String
  }

  func detect(baseURL: URL, session: URLSession) async throws -> ServerVersion {
    var components = URLComponents(
      url: baseURL.appendingPathComponent("/admin/api.php"),
      resolvingAgainstBaseURL: false
    )
    components?.queryItems = [versionQueryItem]

    guard let probeURL = components?.url else {
      throw PiholeError.unknown("Failed to build probe URL")
    }

    var request = URLRequest(url: probeURL)
    request.timeoutInterval = 10

    let (data, response): (Data, URLResponse)
    do {
      (data, response) = try await session.data(for: request)
    } catch {
      throw PiholeError.network(error.localizedDescription)
    }

    guard let httpResponse = response as? HTTPURLResponse else {
      throw PiholeError.unknown("Invalid response during version probe")
    }

    switch httpResponse.statusCode {
    case 200:
      guard
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        json[Self.versionKey] != nil
      else {
        throw PiholeError.unknown(
          "Unexpected response from server. Verify the URL points to a Pi-hole instance."
        )
      }
      logger.debug("Detected Pi-hole v5 via /admin/api.php?version")
      return .v5

    case 400:
      guard
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let hint = hint(from: json),
        hint.contains("/api")
      else {
        throw PiholeError.unknown(
          "Unexpected response from server. Verify the URL points to a Pi-hole instance."
        )
      }
      logger.debug("Detected Pi-hole v6 via structured 400 from /admin/api.php?version")
      return .v6

    default:
      throw PiholeError.unknown(
        "Server did not respond as a Pi-hole instance (HTTP \(httpResponse.statusCode))"
      )
    }
  }
}
