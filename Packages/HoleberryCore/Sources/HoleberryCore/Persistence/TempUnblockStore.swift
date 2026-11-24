import Defaults
import Foundation

/// App-local temporary-unblock records, keyed by server UUID.
///
/// The app owns one of these over its own defaults domain. Records never move to
/// the shared App Group, so a widget launch cannot read or write them.
@MainActor
public final class ConcreteTempUnblockStore: TempUnblockStoring {
  private let suite: UserDefaults

  /// - Parameter suite: App-local defaults. `.standard` in the production app.
  public init(suite: UserDefaults) {
    self.suite = suite
  }

  public func loadTemporaryUnblocks(for serverID: UUID) -> [TempUnblockRecord] {
    Defaults[.tempUnblocks(for: serverID, suite: suite)]
  }

  public func saveTemporaryUnblocks(_ records: [TempUnblockRecord], for serverID: UUID) {
    Defaults[.tempUnblocks(for: serverID, suite: suite)] = records
  }
}
