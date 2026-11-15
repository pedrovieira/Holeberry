import Defaults
import Foundation
import Testing

@testable import HoleberryCore

/// Shared JSON encoder/decoder instances for tests.
/// Using a single instance avoids re-creating these lightweight but commonly-used objects.
enum TestJSON {
  static let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }()

  static let decoder = JSONDecoder()
}

/// Creates an isolated `UserDefaults` suite for a single test.
/// Each call returns a unique, pre-cleaned suite so parallel tests don't interfere.
enum TestDefaults {
  static func makeSuite() -> UserDefaults {
    let name = "com.holeberry.tests.\(UUID().uuidString)"
    guard let suite = UserDefaults(suiteName: name) else {
      fatalError("Failed to create test UserDefaults suite")
    }
    return suite
  }
}

/// Creates the production storage adapter over isolated defaults suites and a
/// mock Keychain, so behavioral tests exercise persistence end to end without
/// touching real storage.
@MainActor
func makeTestStorage(
  appLocalSuite: UserDefaults,
  sharedDataSuite: UserDefaults = TestDefaults.makeSuite(),
  keychain: MockKeychainManager = MockKeychainManager()
) -> ConcreteAppStorage {
  ConcreteAppStorage(
    sharedDataSuite: sharedDataSuite,
    appLocalSuite: appLocalSuite,
    keychain: keychain
  )
}

/// Identity comparison for `any` storage references: the protocol is not
/// class-bound, so `===` cannot take the values directly.
@MainActor
func isSameStorageInstance(_ lhs: (any AppStorageProviding)?, _ rhs: any AppStorageProviding) -> Bool {
  guard let lhs else { return false }
  return (lhs as AnyObject) === (rhs as AnyObject)
}

/// Awaits until `condition` returns true, yielding the main actor between checks.
/// Turn-based, not wall-clock: all test work is serialized on the main actor, so
/// pending sink/`Task` work runs while this yields. `maxTurns` is a safety valve
/// against an infinite loop, not a timing dependency.
@MainActor
func waitUntil(
  maxTurns: Int = 10_000,
  _ condition: @MainActor () -> Bool
) async {
  for _ in 0..<maxTurns {
    if condition() { return }
    await Task.yield()
  }
  Issue.record("waitUntil: condition not met after \(maxTurns) yields")
}

/// Yields enough main-actor turns for any pending sink-emitted work to run.
/// Used for absence assertions (e.g. "no poll was triggered").
@MainActor
func settle(turns: Int = 100) async {
  for _ in 0..<turns {
    await Task.yield()
  }
}
