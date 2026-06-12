import SwiftUI

final class SettingsStore: ObservableObject {
  @Published var recentBlockedCount: Int {
    didSet { UserDefaults.standard.set(recentBlockedCount, forKey: "recentBlockedCount") }
  }
  @Published var maxActiveUnblocks: Int {
    didSet { UserDefaults.standard.set(maxActiveUnblocks, forKey: "maxActiveUnblocks") }
  }
  @Published var launchAtLogin: Bool {
    didSet { UserDefaults.standard.set(launchAtLogin, forKey: "launchAtLogin") }
  }

  init() {
    let storedRecent = UserDefaults.standard.integer(forKey: "recentBlockedCount")
    recentBlockedCount = storedRecent == 0 ? 20 : storedRecent
    let storedMax = UserDefaults.standard.integer(forKey: "maxActiveUnblocks")
    maxActiveUnblocks = storedMax == 0 ? 10 : storedMax
    launchAtLogin = UserDefaults.standard.bool(forKey: "launchAtLogin")
  }
}
