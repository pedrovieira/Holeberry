import Foundation
import OSLog

/// Concrete session actor for a single Pi-hole v6 instance.
///
/// ``AuthV6SessionProvider`` owns the SID and CSRF tokens and serialises all
/// authentication requests through actor isolation so concurrent callers
/// never trigger overlapping logins.
public actor AuthV6SessionProvider: AuthSessionProviding {
  private let host: URL
  private let password: String
  private let urlSession: any HTTPRequestable
  private let logger = Logger(subsystem: Logger.appSubsystem, category: "v6-session")

  private static let apiAuthPath = "/api/auth"
  private static let ftlSIDHeader = "X-FTL-SID"
  private static let encoder = JSONEncoder()
  private static let decoder = JSONDecoder()

  private var sid: String?
  private var csrf: String?
  private var loginTask: Task<AuthResponse, any Error>?

  // MARK: - Init

  public init(
    host: URL,
    password: String,
    urlSession: any HTTPRequestable
  ) {
    self.host = host
    self.password = password
    self.urlSession = urlSession
  }

  // MARK: - AuthSessionProviding

  public func authorizedRequest<T>(
    _ operation: @Sendable (String) async throws -> (T, HTTPURLResponse)
  ) async throws -> T where T: Sendable {
    if sid == nil {
      try await acquireSession()
    }
    guard let currentSid = sid else {
      throw PiholeError.unknown("Session unexpectedly nil after acquire")
    }

    let (result, response) = try await operation(currentSid)

    guard response.statusCode == 401 else { return result }

    // 401 — re-authenticate once and retry once.
    // Actor isolation serialises concurrent callers here.
    logger.debug("Got 401; re-authenticating and retrying once")
    try await acquireSession()
    guard let newSid = sid else {
      throw PiholeError.reauthenticationFailed
    }
    let (retryResult, retryResponse) = try await operation(newSid)

    guard retryResponse.statusCode != 401 else {
      throw PiholeError.reauthenticationFailed
    }
    return retryResult
  }

  public func login() async throws {
    try await acquireSession()
  }

  public func logout() async {
    guard let sid else { return }
    defer {
      self.sid = nil
      self.csrf = nil
    }

    let url = host.appendingPathComponent(Self.apiAuthPath)
    var request = URLRequest(url: url)
    request.httpMethod = "DELETE"
    request.setValue(sid, forHTTPHeaderField: Self.ftlSIDHeader)
    request.timeoutInterval = 10

    _ = try? await urlSession.data(for: request)
  }

  // MARK: - Private

  /// Acquire a session by POSTing to /api/auth.
  ///
  /// Concurrent calls are coalesced: only one actual network request is
  /// made and all callers await the same result.
  private func acquireSession() async throws {
    let authResponse: AuthResponse

    if let existingTask = loginTask {
      authResponse = try await existingTask.value
    } else {
      let task = Task<AuthResponse, any Error> { [host, urlSession, password, logger] in
        let url = host.appendingPathComponent(Self.apiAuthPath)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15

        let bodyDict = ["password": password]
        request.httpBody = try Self.encoder.encode(bodyDict)

        let (data, response): (Data, URLResponse)
        do {
          (data, response) = try await urlSession.data(for: request)
        } catch {
          throw PiholeError.network(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
          throw PiholeError.unknown("Invalid response from auth endpoint")
        }

        guard httpResponse.isSuccess else {
          switch httpResponse.statusCode {
          case 401:
            throw PiholeError.invalidCredentials
          case 429:
            throw PiholeError.rateLimited
          default:
            throw PiholeError.server(httpResponse.statusCode, String(data: data, encoding: .utf8))
          }
        }

        let authResponse: AuthResponse
        do {
          authResponse = try Self.decoder.decode(AuthResponse.self, from: data)
        } catch {
          let body = String(data: data, encoding: .utf8) ?? ""
          logger.error(
            "Auth response decode failed. Status \(httpResponse.statusCode). Body: \(body, privacy: .public)"
          )
          throw PiholeError.decoding(error.localizedDescription)
        }

        if authResponse.totp == true {
          await MainActor.run {
            NotificationCenter.default.post(
              name: .v6SessionTotpRequired,
              object: nil,
              userInfo: ["serverURL": host.absoluteString]
            )
          }
          throw PiholeError.totpRequired
        }

        logger.debug("Authenticated successfully")
        return authResponse
      }

      loginTask = task
      defer { loginTask = nil }

      authResponse = try await task.value
    }

    sid = authResponse.session.sid
    csrf = authResponse.session.csrf
  }
}

// MARK: - Response types

private struct AuthResponse: Decodable {
  let session: Session
  let totp: Bool?

  struct Session: Decodable {
    let sid: String
    let csrf: String?
    let validity: TimeInterval?
  }
}
