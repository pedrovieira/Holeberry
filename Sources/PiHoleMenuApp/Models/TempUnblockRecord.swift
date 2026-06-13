import Foundation

struct TempUnblockRecord: Codable, Identifiable {
  let domain: String
  let uuid: String
  let startDateUTC: Date
  let durationSeconds: TimeInterval
  var piholeEntryId: Int?
  let piHoleVersion: Int
  var pendingRemoval: Bool = false
  var retryCount: Int = 0

  var id: String { uuid }
}
