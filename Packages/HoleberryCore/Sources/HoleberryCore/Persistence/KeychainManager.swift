import Foundation
import LocalAuthentication
import OSLog
import Security
import SimpleKeychain

// MARK: - Protocol

public protocol KeychainManaging: Sendable {
  func saveCredential(_ credential: String, for serverID: UUID) throws
  func readCredential(for serverID: UUID) throws -> String?
  func deleteCredential(for serverID: UUID) throws
}

// MARK: - Concrete Implementation

public final class KeychainManager: KeychainManaging {
  /// Service shared by the app and its widget extension.
  public static let sharedService = Bundle.containingAppIdentifier() + ".shared"

  private static let logger = Logger(subsystem: Logger.appSubsystem, category: "Keychain")

  let service: String
  let accessGroup: String?
  let usesDataProtectionKeychain: Bool
  let isInteractive: Bool
  private let keychain: SimpleKeychain

  /// Defaults preserve the legacy query exactly: the bundle identifier as
  /// service, no access group, no Data Protection Keychain selection, and an
  /// interactive authentication context.
  public init(
    service: String = Bundle.appIdentifier,
    accessGroup: String? = nil,
    useDataProtectionKeychain: Bool = false,
    interactive: Bool = true
  ) {
    let context = LAContext()
    context.localizedReason = "Holeberry needs to access your saved Pi-hole password."
    if !interactive {
      context.interactionNotAllowed = true
    }

    var attributes: [String: Any] = [:]
    if useDataProtectionKeychain {
      attributes[kSecUseDataProtectionKeychain as String] = true
    }

    self.service = service
    self.accessGroup = accessGroup
    self.usesDataProtectionKeychain = useDataProtectionKeychain
    self.isInteractive = interactive
    self.keychain = SimpleKeychain(
      service: service,
      accessGroup: accessGroup,
      context: context,
      attributes: attributes
    )
  }

  /// Shared store used after migration. Widgets pass `interactive: false`.
  public static func shared(accessGroup: String, interactive: Bool) -> KeychainManager {
    Self(
      service: sharedService,
      accessGroup: accessGroup,
      useDataProtectionKeychain: true,
      interactive: interactive
    )
  }

  public func saveCredential(_ credential: String, for serverID: UUID) throws {
    try keychain.set(credential, forKey: serverID.uuidString)
  }

  public func readCredential(for serverID: UUID) throws -> String? {
    let key = serverID.uuidString
    var operation = "hasItem"
    do {
      guard try keychain.hasItem(forKey: key) else { return nil }
      operation = "read"
      return try keychain.string(forKey: key)
    } catch {
      let nsError = error as NSError
      let message =
        "Keychain read failed: operation=\(operation) service=\(service) "
        + "domain=\(nsError.domain) code=\(nsError.code)"
      Self.logger.error("\(message, privacy: .public)")
      throw error
    }
  }

  public func deleteCredential(for serverID: UUID) throws {
    try keychain.deleteItem(forKey: serverID.uuidString)
  }
}

// MARK: - Shared Store With Legacy Cleanup

/// Routes normal credential access to the shared store. Explicit deletion also
/// removes the retained legacy item, but reads never fall back to legacy.
public final class SharedCredentialKeychain: KeychainManaging {
  private let shared: any KeychainManaging
  private let legacy: any KeychainManaging

  public init(shared: any KeychainManaging, legacy: any KeychainManaging) {
    self.shared = shared
    self.legacy = legacy
  }

  public func saveCredential(_ credential: String, for serverID: UUID) throws {
    try shared.saveCredential(credential, for: serverID)
  }

  public func readCredential(for serverID: UUID) throws -> String? {
    try shared.readCredential(for: serverID)
  }

  public func deleteCredential(for serverID: UUID) throws {
    var firstError: (any Error)?

    do {
      if try shared.readCredential(for: serverID) != nil {
        try shared.deleteCredential(for: serverID)
      }
    } catch {
      firstError = error
    }

    do {
      if try legacy.readCredential(for: serverID) != nil {
        try legacy.deleteCredential(for: serverID)
      }
    } catch {
      if firstError == nil {
        firstError = error
      }
    }

    if let firstError {
      throw firstError
    }
  }
}

// MARK: - Unavailable Store

public enum UnavailableKeychainError: Error, Equatable {
  case storageUnavailable
}

/// Throwing credential seam used when previously activated shared storage
/// cannot be reopened. It never falls back to legacy or ungrouped items.
public struct UnavailableKeychain: KeychainManaging {
  public init() {}

  public func saveCredential(_ credential: String, for serverID: UUID) throws {
    throw UnavailableKeychainError.storageUnavailable
  }

  public func readCredential(for serverID: UUID) throws -> String? {
    throw UnavailableKeychainError.storageUnavailable
  }

  public func deleteCredential(for serverID: UUID) throws {
    throw UnavailableKeychainError.storageUnavailable
  }
}
