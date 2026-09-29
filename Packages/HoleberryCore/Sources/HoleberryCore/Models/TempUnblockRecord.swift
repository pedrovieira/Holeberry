import Defaults
import Foundation

public struct TempUnblockRecord: Codable, Identifiable {
  public let domain: String
  public let uuid: String
  public let startDateUTC: Date
  public let durationSeconds: TimeInterval
  public var pendingRemoval: Bool = false
  public var retryCount: Int = 0
  /// Whether the allow entry behind this record is the one Holeberry added, and
  /// is therefore safe to delete on expiry. Records written by builds that
  /// predate the v5 add probe cannot claim that — a duplicate v5 add looked like
  /// a success — and decode as `false`.
  public var ownsAllowEntry: Bool = true

  public var id: String { uuid }

  private enum CodingKeys: String, CodingKey {
    case domain, uuid, startDateUTC, durationSeconds, pendingRemoval, retryCount, ownsAllowEntry
  }
}

// Declared in an extension so the memberwise initializer stays available.
extension TempUnblockRecord {
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    domain = try container.decode(String.self, forKey: .domain)
    uuid = try container.decode(String.self, forKey: .uuid)
    startDateUTC = try container.decode(Date.self, forKey: .startDateUTC)
    durationSeconds = try container.decode(TimeInterval.self, forKey: .durationSeconds)
    pendingRemoval = try container.decodeIfPresent(Bool.self, forKey: .pendingRemoval) ?? false
    retryCount = try container.decodeIfPresent(Int.self, forKey: .retryCount) ?? 0
    // A missing key means the record was written before ownership was tracked.
    ownsAllowEntry = try container.decodeIfPresent(Bool.self, forKey: .ownsAllowEntry) ?? false
  }
}

extension TempUnblockRecord: Defaults.Serializable {}
