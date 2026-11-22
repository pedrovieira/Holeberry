import AppIntents
import Foundation
import HoleberryCore
import WidgetKit

/// The widget's only setting: all saved servers, or one saved server.
struct ServerStatisticsConfigurationIntent: WidgetConfigurationIntent {
  static var title: LocalizedStringResource { "Query statistics" }

  @Parameter(title: "Server")
  var server: ServerStatisticsServerEntity

  /// Absent configuration, including widgets installed before this setting
  /// existed, resolves to the aggregate choice.
  init() {
    server = .allServers
  }

  static var parameterSummary: some ParameterSummary {
    Summary("Statistics for \(\.$server)")
  }
}

/// One choice in the Server picker.
///
/// The identifier is the reserved aggregate identifier or a saved server UUID
/// string. It is never a label, URL, or position in the saved list.
struct ServerStatisticsServerEntity: AppEntity, Hashable {
  /// How the choice resolved against saved server metadata.
  enum Resolution: Hashable, Sendable {
    /// The aggregate choice.
    case aggregate
    /// Saved metadata resolved the server by UUID.
    case saved
    /// Saved metadata is readable and does not contain this UUID.
    case missing
    /// Saved metadata is unavailable, so the choice cannot be classified.
    case unavailable
  }

  static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Pi-hole server")
  static let defaultQuery = ServerStatisticsServerQuery()

  /// The default choice, used when a widget has no explicit configuration.
  static let allServers = ServerStatisticsServerEntity(
    id: ServerStatisticsSelection.allServersIdentifier,
    name: "All servers",
    detail: nil,
    resolution: .aggregate
  )

  let id: String
  /// The current display name, resolved when the query runs.
  let name: String
  /// A hostname or URL when saved names are duplicated.
  let detail: String?
  /// The semantic state behind the display values.
  let resolution: Resolution

  var scope: ServerScope {
    ServerStatisticsSelection.scope(for: id)
  }

  var displayRepresentation: DisplayRepresentation {
    DisplayRepresentation(
      title: LocalizedStringResource(stringLiteral: name),
      subtitle: detail.map { LocalizedStringResource(stringLiteral: $0) }
    )
  }
}

/// Lists saved servers from shared storage without network or Keychain access.
struct ServerStatisticsServerQuery: EntityQuery {
  func entities(for identifiers: [String]) async throws -> [ServerStatisticsServerEntity] {
    let saved = await Self.savedMetadata()
    return identifiers.map { Self.entity(for: $0, saved: saved) }
  }

  func suggestedEntities() async throws -> [ServerStatisticsServerEntity] {
    let saved = await Self.savedMetadata()
    return [.allServers] + (saved ?? []).map(Self.entity(for:))
  }

  /// Preserves every explicit identifier, including one whose server is gone.
  ///
  /// The resolution state is explicit rather than inferred from the display
  /// name, because a saved server may legitimately be named "Server removed".
  static func entity(
    for identifier: String,
    saved: [SavedServerMetadata]?
  ) -> ServerStatisticsServerEntity {
    guard identifier != ServerStatisticsSelection.allServersIdentifier else {
      return .allServers
    }
    if let metadata = saved?.first(where: {
      $0.id.uuidString.caseInsensitiveCompare(identifier) == .orderedSame
    }) {
      return entity(for: metadata)
    }
    guard saved != nil else {
      return ServerStatisticsServerEntity(
        id: identifier,
        name: "Server",
        detail: nil,
        resolution: .unavailable
      )
    }
    return ServerStatisticsServerEntity(
      id: identifier,
      name: "Server removed",
      detail: nil,
      resolution: .missing
    )
  }

  private static func entity(for metadata: SavedServerMetadata) -> ServerStatisticsServerEntity {
    ServerStatisticsServerEntity(
      id: metadata.id.uuidString,
      name: metadata.name,
      detail: metadata.detail,
      resolution: .saved
    )
  }

  /// Reads picker metadata only when shared storage is ready.
  private static func savedMetadata() async -> [SavedServerMetadata]? {
    await MainActor.run {
      guard let appGroupIdentifier = try? Bundle.main.sharedAppGroupIdentifier(),
        let suite = try? UserDefaults.sharedStorageSuite(appGroupIdentifier: appGroupIdentifier)
      else {
        return nil
      }
      return SavedServerCatalog.metadata(in: suite, suiteName: appGroupIdentifier)
    }
  }
}
