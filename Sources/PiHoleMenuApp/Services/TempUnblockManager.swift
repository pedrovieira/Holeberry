import Foundation
import OSLog

final class TempUnblockManager {
  static let shared = TempUnblockManager()

  @Published private(set) var activeRecords: [TempUnblockRecord] = []

  private let logger = Logger(subsystem: Logger.appSubsystem, category: "temp-unblock")
  private static let decoder = JSONDecoder()
  private static let encoder = JSONEncoder()
  private let defaults = UserDefaults.standard
  private let storageKey = "tempUnblocks"

  init() {
    activeRecords = restoreFromUserDefaults()
  }

  func add(domain: String, duration: TimeInterval, service: PiholeServiceProtocol) async throws -> TempUnblockRecord {
    let uuid = "pihole-menu-app:\(UUID().uuidString)"

    try await service.addDomain(domain, to: .allow, comment: uuid)

    let record = TempUnblockRecord(
      domain: domain,
      uuid: uuid,
      startDateUTC: Date(),
      durationSeconds: duration
    )

    activeRecords.append(record)
    saveRecords()
    logger.info("Added temp unblock for \(domain, privacy: .public) (\(duration)s)")
    return record
  }

  func remove(record: TempUnblockRecord) {
    activeRecords.removeAll { $0.uuid == record.uuid }
    saveRecords()
    logger.info("Removed temp unblock for \(record.domain, privacy: .public)")
  }

  func restoreFromUserDefaults() -> [TempUnblockRecord] {
    guard let data = defaults.data(forKey: storageKey) else { return [] }
    guard let records = try? Self.decoder.decode([TempUnblockRecord].self, from: data) else {
      logger.warning("Failed to decode temp unblock records")
      return []
    }

    let now = Date()
    return records.filter { $0.startDateUTC.addingTimeInterval($0.durationSeconds) > now }
  }

  private func saveRecords() {
    do {
      let data = try Self.encoder.encode(activeRecords)
      defaults.set(data, forKey: storageKey)
    } catch {
      logger.error("Failed to save temp unblock records: \(error.localizedDescription, privacy: .public)")
    }
  }
}
