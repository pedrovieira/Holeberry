import Defaults
import Foundation

public struct TempUnblockRecord: Codable, Identifiable {
  public let domain: String
  public let uuid: String
  public let startDateUTC: Date
  public let durationSeconds: TimeInterval
  public var pendingRemoval: Bool = false
  public var retryCount: Int = 0

  public var id: String { uuid }
}

extension TempUnblockRecord: Defaults.Serializable {}
