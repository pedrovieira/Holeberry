import Foundation
import SimpleKeychain

final class KeychainManager: Sendable {
  static let shared = KeychainManager()
  private let keychain: SimpleKeychain

  init() {
    self.keychain = SimpleKeychain(service: Bundle.main.bundleIdentifier ?? "me.pedrovieira.holeberry")
  }

  func saveCredential(_ credential: String, for serverID: UUID) throws {
    try keychain.set(credential, forKey: serverID.uuidString)
  }

  func readCredential(for serverID: UUID) throws -> String? {
    let key = serverID.uuidString
    guard try keychain.hasItem(forKey: key) else { return nil }
    return try keychain.string(forKey: key)
  }

  func deleteCredential(for serverID: UUID) throws {
    try keychain.deleteItem(forKey: serverID.uuidString)
  }
}
