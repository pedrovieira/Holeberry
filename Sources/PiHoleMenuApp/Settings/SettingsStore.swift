import SwiftUI

final class SettingsStore: ObservableObject {
  @AppStorage("serverURL") var serverURL = ""
  @AppStorage("recentBlockedCount") var recentBlockedCount = 20
  @AppStorage("maxActiveUnblocks") var maxActiveUnblocks = 10
  @AppStorage("trustSelfSigned") var trustSelfSigned = false
  @AppStorage("launchAtLogin") var launchAtLogin = false
}
