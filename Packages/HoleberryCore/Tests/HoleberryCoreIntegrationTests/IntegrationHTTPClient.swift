import Foundation
import OSLog

@testable import HoleberryCore

/// Real ephemeral transport for one integration lane.
///
/// Bytes and status codes are forwarded unchanged to the production service.
/// Only the method, query-free path and response status are logged; request and
/// response bodies, headers, cookies and credentials are never rendered.
final class IntegrationHTTPClient: HTTPRequestable {
  private let session: URLSession
  private let redactor: IntegrationRedactor
  private let laneLabel: String
  private let logger = Logger(subsystem: Logger.appSubsystem, category: "integration-http")

  init(lane: IntegrationLane, redactor: IntegrationRedactor) {
    self.redactor = redactor
    self.laneLabel = lane.version.rawValue

    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 15
    // The production gravity request pins 900 seconds per request; keep the
    // resource bound above it so the transport never truncates a real update.
    configuration.timeoutIntervalForResource = 960
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.httpCookieAcceptPolicy = .never
    configuration.httpShouldSetCookies = false
    configuration.urlCache = nil
    self.session = URLSession(configuration: configuration)
  }

  deinit {
    session.invalidateAndCancel()
  }

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    let method = request.httpMethod ?? "GET"
    let path = request.url?.path ?? "<unknown>"

    do {
      let (data, response) = try await session.data(for: request)
      let status = (response as? HTTPURLResponse)?.statusCode ?? -1
      logger.debug(
        """
        lane=\(self.laneLabel, privacy: .public) method=\(method, privacy: .public) \
        path=\(path, privacy: .public) status=\(status, privacy: .public) \
        bytes=\(data.count, privacy: .public)
        """
      )
      return (data, response)
    } catch {
      let errorType = redactor.sanitize(String(describing: type(of: error)))
      logger.error(
        """
        lane=\(self.laneLabel, privacy: .public) method=\(method, privacy: .public) \
        path=\(path, privacy: .public) failed=\(errorType, privacy: .public)
        """
      )
      throw error
    }
  }

  func invalidateAndCancel() {
    session.invalidateAndCancel()
  }
}
