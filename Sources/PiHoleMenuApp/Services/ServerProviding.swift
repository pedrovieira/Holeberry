import Foundation

protocol ServerProviding: AnyObject {
  var servers: [PiholeServer] { get }
  func perform<T>(
    for server: PiholeServer,
    block: (PiholeServiceProtocol) async throws -> T
  ) async throws -> T
}
