import Foundation
import LocalAuthentication
import SimpleKeychain

// MARK: - Protocol

public protocol KeychainManaging: Sendable {
  func saveCredential(_ credential: String, for serverID: UUID) throws
  func readCredential(for serverID: UUID) throws -> String?
  func deleteCredential(for serverID: UUID) throws
}

// MARK: - Concrete Implementation

public final class KeychainManager: KeychainManaging {
  private let keychain: SimpleKeychain

  public init() {
    let context = LAContext()
    context.localizedReason = "Holeberry needs to access your saved Pi-hole password."

    let attributes: [String: Any] = [
      kSecUseDataProtectionKeychain as String: true
    ]
    self.keychain = SimpleKeychain(
      service: Bundle.main.bundleIdentifier ?? "me.pedrovieira.holeberry",
      accessibility: .afterFirstUnlock,
      context: context,
      attributes: attributes
    )
  }

  public func saveCredential(_ credential: String, for serverID: UUID) throws {
    try keychain.set(credential, forKey: serverID.uuidString)
  }

  public func readCredential(for serverID: UUID) throws -> String? {
    let key = serverID.uuidString
    guard try keychain.hasItem(forKey: key) else { return nil }
    return try keychain.string(forKey: key)
  }

  public func deleteCredential(for serverID: UUID) throws {
    try keychain.deleteItem(forKey: serverID.uuidString)
  }
}
