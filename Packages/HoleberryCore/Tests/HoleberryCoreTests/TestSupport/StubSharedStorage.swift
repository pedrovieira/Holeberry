@testable import HoleberryCore

@MainActor
final class StubSharedStorage: SharedStorageProviding {
  let locationValue: SharedStorageLocation
  let keychainValue: any KeychainManaging
  var locationError: (any Error)?
  var keychainError: (any Error)?
  private(set) var keychainCallCount = 0

  init(location: SharedStorageLocation, keychain: any KeychainManaging) {
    locationValue = location
    keychainValue = keychain
  }

  func location() throws -> SharedStorageLocation {
    if let locationError { throw locationError }
    return locationValue
  }

  func keychain() throws -> any KeychainManaging {
    keychainCallCount += 1
    if let keychainError { throw keychainError }
    return keychainValue
  }
}
