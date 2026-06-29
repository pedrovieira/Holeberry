import Foundation

@MainActor
protocol ServerProviding: AnyObject {
  var servers: [ServerConfig] { get }
  func perform<T>(
    for id: UUID,
    block: (PiholeServiceProtocol) async throws -> T
  ) async throws -> T
}
