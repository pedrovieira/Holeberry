import Foundation

/// Runs one Pi-hole operation against the supplied services concurrently.
///
/// Shared by the app manager and the widget's on-demand client. Each caller owns
/// target selection, service construction, credentials, and lifecycle; this
/// helper owns only the task group and the per-server result and error mapping.
@MainActor
func performPiholeOperation<Value: Sendable>(
  serverIDs: [UUID],
  services: [UUID: any PiholeServiceProviding],
  operation: @escaping @MainActor @Sendable (any PiholeServiceProviding) async throws -> Value
) async -> [UUID: Result<Value, PiholeError>] {
  await withTaskGroup(of: (UUID, Result<Value, PiholeError>).self) { group in
    for id in serverIDs {
      let service = services[id]
      group.addTask {
        guard let service else {
          return (id, .failure(.unknown("Server not found")))
        }
        do {
          return (id, .success(try await operation(service)))
        } catch {
          return (id, .failure(error as? PiholeError ?? .unknown(error.localizedDescription)))
        }
      }
    }
    var results: [UUID: Result<Value, PiholeError>] = [:]
    for await (id, result) in group {
      results[id] = result
    }
    return results
  }
}
