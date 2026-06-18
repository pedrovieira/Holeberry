import Foundation
import OSLog

extension Notification.Name {
  static let authManagerTotpRequired = Notification.Name("authManagerTotpRequired")
}

/// Manages Pi-hole v6 session lifecycle: login, proactive refresh before expiry, and reactive 401 retry.
actor AuthManager {
  private let baseURL: URL
  private let session: URLSession
  private let logger = Logger(subsystem: Logger.appSubsystem, category: "auth")

  private static let passwordKey = "password"
  private static let totpKey = "totp"
  private static let ftlSIDHeader = "X-FTL-SID"
  private static let ftlCSRFHeader = "X-FTL-CSRF"

  private var sid: String?
  private var csrf: String?
  private var validity: TimeInterval?
  private var loginDate: Date?
  private var isAuthenticated = false
  private var refreshTask: Task<Void, Never>?
  private var loginTask: Task<Void, Error>?

  init(baseURL: URL, session: URLSession) {
    self.baseURL = baseURL
    self.session = session
  }

  var isLoggedIn: Bool { isAuthenticated }

  func login(password: String, totp: String? = nil) async throws {
    if isAuthenticated { return }
    if let existingTask = loginTask {
      return try await existingTask.value
    }
    let task = Task { [weak self] in
      guard let self else { throw PiholeError.unknown("AuthManager deallocated") }
      try await self.performLogin(password: password, totp: totp)
    }
    loginTask = task
    defer { loginTask = nil }
    try await task.value
  }

  private func performLogin(password: String, totp: String? = nil) async throws {
    cancelRefresh()

    let url = baseURL.appendingPathComponent("/api/auth")
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.timeoutInterval = 15

    var bodyDict: [String: String] = [Self.passwordKey: password]
    if let totp {
      bodyDict[Self.totpKey] = totp
    }
    request.httpBody = try JSONEncoder().encode(bodyDict)

    let (data, response): (Data, URLResponse)
    do {
      (data, response) = try await session.data(for: request)
    } catch {
      throw PiholeError.network(error.localizedDescription)
    }

    guard let httpResponse = response as? HTTPURLResponse else {
      throw PiholeError.unknown("Invalid response from auth endpoint")
    }

    if httpResponse.statusCode == 401 {
      throw PiholeError.unauthorized
    }

    guard httpResponse.statusCode == 200 else {
      throw PiholeError.server(httpResponse.statusCode, String(data: data, encoding: .utf8))
    }

    let authResponse: AuthResponse
    do {
      authResponse = try JSONDecoder().decode(AuthResponse.self, from: data)
    } catch {
      let body = String(data: data, encoding: .utf8) ?? ""
      self.logger.error(
        "Auth response decode failed. Status \(httpResponse.statusCode). Body: \(body, privacy: .public)"
      )
      throw PiholeError.decoding(error.localizedDescription)
    }

    if authResponse.totp == true && totp == nil {
      throw PiholeError.totpRequired
    }

    sid = authResponse.session.sid
    csrf = authResponse.session.csrf
    validity = authResponse.session.validity
    loginDate = Date()
    isAuthenticated = true

    logger.debug("Authenticated successfully; SID valid for \(authResponse.session.validity ?? 0, privacy: .public)s")
    scheduleRefresh(password: password, totp: totp)
  }

  func logout() async {
    cancelRefresh()
    guard let sid else { return }

    let url = baseURL.appendingPathComponent("/api/auth")
    var request = URLRequest(url: url)
    request.httpMethod = "DELETE"
    request.setValue(sid, forHTTPHeaderField: Self.ftlSIDHeader)
    request.timeoutInterval = 10

    _ = try? await session.data(for: request)

    self.sid = nil
    self.csrf = nil
    self.validity = nil
    self.loginDate = nil
    isAuthenticated = false
  }

  func authHeaders() throws -> [String: String] {
    guard let sid, isAuthenticated else {
      throw PiholeError.unauthorized
    }
    var headers: [String: String] = [:]
    headers[Self.ftlSIDHeader] = sid
    if let csrf {
      headers[Self.ftlCSRFHeader] = csrf
    }
    return headers
  }

  func reauthenticate(password: String, totp: String? = nil) async throws {
    logger.debug("Re-authenticating (proactive refresh)")
    try await performLogin(password: password, totp: totp)
  }

  private func scheduleRefresh(password: String, totp: String?) {
    guard let validity else { return }
    let refreshIn = max(validity - 50, 10)

    refreshTask = Task { [weak self] in
      do {
        try await Task.sleep(nanoseconds: UInt64(refreshIn * 1_000_000_000))
        guard !Task.isCancelled else { return }
        try await self?.reauthenticate(password: password, totp: totp)
      } catch is CancellationError {
        return
      } catch PiholeError.totpRequired {
        await MainActor.run {
          NotificationCenter.default.post(
            name: .authManagerTotpRequired,
            object: nil,
            userInfo: ["serverURL": self?.baseURL.absoluteString ?? ""]
          )
        }
        self?.logger.warning("Proactive auth refresh requires TOTP — user should use an application password")
      } catch {
        self?.logger.warning("Proactive auth refresh failed: \(error.localizedDescription, privacy: .public)")
      }
    }
  }

  private func cancelRefresh() {
    refreshTask?.cancel()
    refreshTask = nil
  }
}

private struct AuthResponse: Decodable {
  let session: Session
  let totp: Bool?
  struct Session: Decodable {
    let sid: String
    let csrf: String?
    let validity: TimeInterval?
  }
}
