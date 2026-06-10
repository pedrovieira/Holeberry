import SwiftUI

struct MenuContentView: View {
  var body: some View {
    Text("● Pi-hole Status")
      .foregroundColor(.secondary)

    Divider()

    Text("Disable Blocking")
      .foregroundColor(.secondary)
    Text("Recent Blocked")
      .foregroundColor(.secondary)

    Divider()

    Button("Settings...") {
      SettingsWindowController.shared.showWindow()
    }
    .keyboardShortcut(",")

    Divider()

    Button("Quit") {
      NSApplication.shared.terminate(nil)
    }
    .keyboardShortcut("q")
  }
}
