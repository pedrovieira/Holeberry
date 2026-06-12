import Foundation
import OSLog

@propertyWrapper
struct ServerStorage {
  private let key = "servers"
  private let defaultValue: [PiholeServer] = []
  private let logger = Logger(subsystem: Logger.appSubsystem, category: "storage")

  var wrappedValue: [PiholeServer] {
    get { load() }
    set { save(newValue) }
  }

  init() {}

  private func load() -> [PiholeServer] {
    guard let data = UserDefaults.standard.data(forKey: key) else { return defaultValue }
    guard let servers = try? JSONDecoder().decode([PiholeServer].self, from: data) else {
      logger.warning("Failed to decode servers from UserDefaults — resetting")
      UserDefaults.standard.removeObject(forKey: key)
      return defaultValue
    }
    return servers
  }

  private func save(_ servers: [PiholeServer]) {
    guard let data = try? JSONEncoder().encode(servers) else { return }
    UserDefaults.standard.set(data, forKey: key)
  }
}
