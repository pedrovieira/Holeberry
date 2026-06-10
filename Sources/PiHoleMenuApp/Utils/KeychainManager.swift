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
}
