import Foundation
import HoleberryCore

/// Stable configuration identifiers for the widget's server selection.
///
/// The configuration stores only these identifiers. Server identity is the
/// saved UUID, never a label, URL, or position in the saved list.
enum ServerStatisticsSelection {
  /// The explicit aggregate choice.
  static let allServersIdentifier = "all"

  /// A malformed explicit identifier maps here, so it can never resolve to the
  /// aggregate scope or match a saved server.
  static let unreadableServerID = UUID(
    uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
  )

  static func identifier(for scope: ServerScope) -> String {
    switch scope {
    case .all:
      return allServersIdentifier
    case .server(let id):
      return id.uuidString
    }
  }

  /// Resolves an explicit identifier into the scope it describes.
  ///
  /// An explicit server choice never falls back to the aggregate scope, even
  /// when its server is missing or its identifier is unreadable.
  static func scope(for identifier: String) -> ServerScope {
    guard identifier != allServersIdentifier else { return .all }
    guard let id = UUID(uuidString: identifier) else { return .server(unreadableServerID) }
    return .server(id)
  }

  /// The entry to show before real data loads for a configured selection.
  ///
  /// Sample counts appear only for the aggregate choice and a resolved saved
  /// server. A missing server keeps the approved removal guidance, and
  /// unavailable metadata keeps setup guidance, so neither invents numbers.
  static func previewEntry(
    for selection: ServerStatisticsServerEntity,
    now: Date = Date()
  ) -> QueryStatisticsEntry {
    switch selection.resolution {
    case .aggregate:
      return .placeholder(now: now)
    case .saved:
      return .placeholder(now: now, scope: selection.scope, serverName: selection.name)
    case .missing:
      return .empty(now: now, scope: selection.scope)
    case .unavailable:
      return .setupRequired(now: now, scope: selection.scope)
    }
  }
}
