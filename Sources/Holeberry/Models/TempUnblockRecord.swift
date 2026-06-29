import Defaults
import Foundation

struct TempUnblockRecord: Codable, Identifiable {
  let domain: String
  let uuid: String
  let startDateUTC: Date
  let durationSeconds: TimeInterval
  var pendingRemoval: Bool = false
  var retryCount: Int = 0

  var id: String { uuid }
}

extension TempUnblockRecord: Defaults.Serializable {}
