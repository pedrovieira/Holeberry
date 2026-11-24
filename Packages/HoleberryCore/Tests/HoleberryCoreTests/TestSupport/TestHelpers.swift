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
    makeNamedSuite().suite
  }

  /// Same isolated suite, with the domain name kept so tests can snapshot the
  /// exact persistent domain instead of the merged search list.
  static func makeNamedSuite() -> (name: String, suite: UserDefaults) {
    let name = "com.holeberry.tests.\(UUID().uuidString)"
    guard let suite = UserDefaults(suiteName: name) else {
      fatalError("Failed to create test UserDefaults suite")
    }
    return (name, suite)
  }
}

/// Creates the production connection store over an isolated defaults suite and
/// a mock Keychain, so behavioral tests exercise persistence end to end without
/// touching real storage.
@MainActor
func makeTestConnectionStore(
  sharedData: UserDefaults = TestDefaults.makeSuite(),
  keychain: MockKeychainManager = MockKeychainManager(),
  legacyKeychain: (any KeychainManaging)? = nil
) -> ConcreteConnectionStore {
  ConcreteConnectionStore(
    suite: sharedData,
    keychain: keychain,
    legacyKeychain: legacyKeychain
  )
}

/// Creates the production app-local temporary-unblock store over an isolated
/// defaults suite.
@MainActor
func makeTestTempUnblockStore(suite: UserDefaults = TestDefaults.makeSuite()) -> ConcreteTempUnblockStore {
  ConcreteTempUnblockStore(suite: suite)
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
