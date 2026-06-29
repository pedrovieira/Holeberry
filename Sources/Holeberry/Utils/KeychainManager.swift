import Foundation
import SimpleKeychain

final class KeychainManager: Sendable {
  static let shared = KeychainManager()
  private let keychain: SimpleKeychain

  init(service: String = "me.pedrovieira.holeberry") {
    self.keychain = SimpleKeychain(service: service)
  }

  func saveCredential(_ credential: String, for serverURL: String) throws {
    try keychain.set(credential, forKey: serverURL)
  }

  func readCredential(for serverURL: String) throws -> String? {
    guard try keychain.hasItem(forKey: serverURL) else { return nil }
    return try keychain.string(forKey: serverURL)
  }

  func deleteCredential(for serverURL: String) throws {
    try keychain.deleteItem(forKey: serverURL)
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
