import Foundation
import Subprocess

/// A failed `docker compose exec` call.
struct ContainerCommandError: Error, LocalizedError, CustomStringConvertible, CustomDebugStringConvertible {
  let service: String
  let arguments: [String]
  let status: String
  let output: String

  var errorDescription: String? {
    let command = (["docker", "compose", "exec", service] + arguments).joined(separator: " ")
    let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
    return "\(command) failed with \(status)\(detail.isEmpty ? "" : ": \(detail.prefix(2_000))")"
  }

  var description: String {
    errorDescription ?? "Container command failed."
  }

  var debugDescription: String {
    description
  }
}

/// The three disposable Pi-hole services from `Containers/compose.yml`.
enum ContainerService: String, Sendable {
  case v5 = "pihole-v5"
  case v6 = "pihole-v6"
  case v6Open = "pihole-v6-open"
}

private struct APISessionsResponse: Decodable {
  let sessions: [Session]

  struct Session: Decodable {
    let id: Int
    let valid: Bool
    let currentSession: Bool

    enum CodingKeys: String, CodingKey {
      case id, valid
      case currentSession = "current_session"
    }
  }
}

/// Runs Pi-hole CLI commands inside the integration containers.
///
/// Some prerequisites and side-effect assertions need the Pi-hole CLI, which is
/// not reachable through the app's API.
@MainActor
struct ContainerCLI {
  private static let outputLimit = 1 << 20

  let composeFile: URL

  init(composeFile: URL = IntegrationEnvironment.composeFile) {
    self.composeFile = composeFile
  }

  /// Xcode test runs can start with a minimal PATH that omits Homebrew and
  /// OrbStack, so search the usual Docker locations as well.
  private static var subprocessEnvironment: Subprocess.Environment {
    let fallbacks = [
      "/opt/homebrew/bin",
      "/usr/local/bin",
      "\(NSHomeDirectory())/.orbstack/bin",
      "\(NSHomeDirectory())/.docker/bin"
    ]
    var parts = (ProcessInfo.processInfo.environment["PATH"] ?? "")
      .split(separator: ":")
      .map(String.init)
    for path in fallbacks where !parts.contains(path) {
      parts.append(path)
    }
    return Subprocess.Environment.inherit.updating(["PATH": parts.joined(separator: ":")])
  }

  @discardableResult
  func run(
    _ service: ContainerService,
    _ arguments: String...,
    timeout: Duration = .seconds(180)
  ) async throws -> String {
    try await run(service, arguments: arguments, timeout: timeout)
  }

  @discardableResult
  func run(
    _ service: ContainerService,
    arguments: [String],
    timeout: Duration = .seconds(180)
  ) async throws -> String {
    guard FileManager.default.fileExists(atPath: composeFile.path) else {
      throw ContainerCommandError(
        service: service.rawValue,
        arguments: arguments,
        status: "missing compose file",
        output: composeFile.path
      )
    }

    let command =
      ["compose", "--file", composeFile.path, "exec", "-T", service.rawValue] + arguments

    return try await withThrowingTaskGroup(of: String.self) { group in
      group.addTask {
        do {
          let result = try await Subprocess.run(
            .name("docker"),
            arguments: Arguments(command),
            environment: Self.subprocessEnvironment,
            output: .string(limit: Self.outputLimit),
            error: .string(limit: Self.outputLimit)
          )
          guard result.terminationStatus.isSuccess else {
            throw ContainerCommandError(
              service: service.rawValue,
              arguments: arguments,
              status: String(describing: result.terminationStatus),
              output: result.standardError.isEmpty ? result.standardOutput : result.standardError
            )
          }
          return result.standardOutput
        } catch let error as ContainerCommandError {
          throw error
        } catch {
          throw ContainerCommandError(
            service: service.rawValue,
            arguments: arguments,
            status: "launch failure",
            output: String(describing: error)
          )
        }
      }

      group.addTask {
        try await Task.sleep(for: timeout)
        throw ContainerCommandError(
          service: service.rawValue,
          arguments: arguments,
          status: "timeout",
          output: "timed out"
        )
      }

      do {
        guard let output = try await group.next() else {
          throw ContainerCommandError(
            service: service.rawValue,
            arguments: arguments,
            status: "no result",
            output: ""
          )
        }
        group.cancelAll()
        return output
      } catch {
        group.cancelAll()
        throw error
      }
    }
  }

  /// Reads live v6 API sessions through Pi-hole's own CLI. The CLI creates and
  /// removes its own observer session; exclude it from the returned IDs.
  func activeAPISessionIDs(_ service: ContainerService) async throws -> Set<Int> {
    let output = try await run(service, "pihole", "api", "auth/sessions")
    let response = try JSONDecoder().decode(APISessionsResponse.self, from: Data(output.utf8))
    return Set(response.sessions.filter { $0.valid && !$0.currentSession }.map(\.id))
  }

  /// Revokes one app session using an independent CLI-authenticated session.
  /// The CLI wrapper only supports GET, so use its auth helpers for this DELETE.
  func revokeAPISession(_ id: Int, on service: ContainerService) async throws -> String {
    let script = """
      set -e
      . /opt/pihole/api.sh
      LoginAPI
      trap 'LogoutAPI' EXIT
      curl --fail --silent --show-error --connect-timeout 5 --max-time 15 \
        --request DELETE "${API_URL}auth/session/$1" --header "sid: ${SID}" \
        --output /dev/null --write-out '%{http_code}'
      """
    return try await run(service, "sh", "-c", script, "holeberry-revoke-session", String(id))
  }

  /// Reads the initialized v5 web password, which is also the legacy API token.
  func v5Token() async throws -> String {
    let output = try await run(
      .v5,
      "sh", "-c", "grep -m1 '^WEBPASSWORD=' /etc/pihole/setupVars.conf"
    )
    guard
      let line = output.split(whereSeparator: \.isNewline).first,
      let separator = line.firstIndex(of: "=")
    else {
      throw ContainerCommandError(
        service: ContainerService.v5.rawValue,
        arguments: ["token"],
        status: "invalid output",
        output: "WEBPASSWORD is missing from setupVars.conf"
      )
    }
    let token = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
    guard !token.isEmpty else {
      throw ContainerCommandError(
        service: ContainerService.v5.rawValue,
        arguments: ["token"],
        status: "invalid output",
        output: "WEBPASSWORD is empty in setupVars.conf"
      )
    }
    return token
  }
}
