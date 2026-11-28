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
  static let allServersIdentifier = "all"

  private static let unreadableServerID = UUID(
    uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
  )

  /// The default choice, used when a widget has no explicit configuration.
  static let allServers = ServerStatisticsServerEntity(
    id: allServersIdentifier,
    name: "All servers",
    detail: nil,
    resolution: .aggregate
  )

  let id: String
  /// The current display name, resolved when the query runs.
  let name: String
  /// A hostname when saved names are duplicated; nothing from the saved URL.
  let detail: String?
  /// The semantic state behind the display values.
  let resolution: Resolution

  var scope: ServerScope {
    guard id != Self.allServersIdentifier else { return .all }
    return .server(UUID(uuidString: id) ?? Self.unreadableServerID)
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
  /// Reads saved servers. `nil` means saved metadata is unavailable.
  typealias SavedServersReader = @MainActor () -> [ServerConfig]?

  private let readSavedServers: SavedServersReader

  init() {
    self.init { try? SharedStorageReader().servers() }
  }

  /// Lets a caller supply the saved-server source, such as a completed store.
  init(readSavedServers: @escaping SavedServersReader) {
    self.readSavedServers = readSavedServers
  }

  func defaultResult() async -> ServerStatisticsServerEntity? {
    .allServers
  }

  func entities(for identifiers: [String]) async throws -> [ServerStatisticsServerEntity] {
    let saved = await readSavedServers()
    return identifiers.map { Self.entity(for: $0, saved: saved) }
  }

  func suggestedEntities() async throws -> IntentItemCollection<ServerStatisticsServerEntity> {
    let servers = await readSavedServers() ?? []
    var sections = [
      IntentItemSection<ServerStatisticsServerEntity> {
        ServerStatisticsServerEntity.allServers
      }
    ]
    if !servers.isEmpty {
      sections.append(IntentItemSection("Individual servers", items: Self.choices(for: servers)))
    }
    return IntentItemCollection(sections: sections)
  }

  /// Preserves every explicit identifier, including one whose server is gone.
  ///
  /// The resolution state is explicit rather than inferred from the display
  /// name, because a saved server may legitimately be named "Server removed".
  static func entity(
    for identifier: String,
    saved: [ServerConfig]?
  ) -> ServerStatisticsServerEntity {
    guard identifier != ServerStatisticsServerEntity.allServersIdentifier else {
      return .allServers
    }
    if let entity = choices(for: saved ?? []).first(where: {
      $0.id.caseInsensitiveCompare(identifier) == .orderedSame
    }) {
      return entity
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

  /// Maps saved configurations directly to picker choices, disambiguating names.
  ///
  /// Only the hostname may appear as a subtitle: the saved URL can carry a
  /// username, password, path, query, or fragment. Equal hostnames stay
  /// indistinguishable instead of falling back to any part of the saved URL.
  static func choices(for servers: [ServerConfig]) -> [ServerStatisticsServerEntity] {
    let nameCounts = Dictionary(grouping: servers, by: \.displayName).mapValues(\.count)
    return servers.map { server in
      ServerStatisticsServerEntity(
        id: server.id.uuidString,
        name: server.displayName,
        detail: nameCounts[server.displayName, default: 0] > 1 ? server.url.hostname : nil,
        resolution: .saved
      )
    }
  }
}

// Keep App Intents preview construction in the widget target; the app compiles
// the entry separately to host SwiftUI previews without App Intents adapters.
extension QueryStatisticsEntry {
  /// Samples resolved choices; missing or unavailable choices show guidance.
  static func preview(
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
