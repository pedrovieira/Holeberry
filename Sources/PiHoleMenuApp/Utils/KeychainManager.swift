import Foundation
import SimpleKeychain

final class KeychainManager: Sendable {
  static let shared = KeychainManager()
  private let keychain: SimpleKeychain

  init(service: String = "com.pihole.menuapp") {
    self.keychain = SimpleKeychain(service: service)
  }

  func savePassword(_ password: String, for serverURL: String) throws {
    try keychain.set(password, forKey: serverURL)
  }

  func readPassword(for serverURL: String) throws -> String? {
    guard try keychain.hasItem(forKey: serverURL) else { return nil }
    return try keychain.string(forKey: serverURL)
  }

  func deletePassword(for serverURL: String) throws {
    try keychain.deleteItem(forKey: serverURL)
  }

  func savePassword(_ password: String, for serverID: UUID) throws {
    try keychain.set(password, forKey: serverID.uuidString)
  }

  func readPassword(for serverID: UUID) throws -> String? {
    let key = serverID.uuidString
    guard try keychain.hasItem(forKey: key) else { return nil }
    return try keychain.string(forKey: key)
  }

  func deletePassword(for serverID: UUID) throws {
    try keychain.deleteItem(forKey: serverID.uuidString)
  }
}
