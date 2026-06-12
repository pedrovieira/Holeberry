import SwiftUI

struct MenuContentView: View {
  @StateObject private var manager = PiholeServerManager()

  var body: some View {
    if manager.servers.isEmpty {
      Text("No instances configured")
        .foregroundColor(.secondary)
      Text("Open Settings to add a Pi-hole")
        .font(.caption)
        .foregroundColor(.secondary)
    } else {
      statusSection
      Divider()
      ForEach(manager.servers) { server in
        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 6) {
            Circle()
              .fill(server.version != nil ? Color.green : Color.red)
              .frame(width: 8, height: 8)
            Text(server.label ?? server.url)
              .font(.system(size: 12))
          }
          if let version = server.version {
            Text(version.displayName)
              .font(.system(size: 10))
              .foregroundColor(.secondary)
          } else {
            Text("Connection error")
              .font(.system(size: 10))
              .foregroundColor(.red)
          }
        }
        .padding(.vertical, 2)
      }
    }

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

  private var statusSection: some View {
    VStack(alignment: .leading, spacing: 2) {
      Label("Pi-hole Active", systemImage: "shield.fill")
        .foregroundColor(.green)
      Text("\(manager.servers.count) instance(s) configured")
        .font(.caption)
        .foregroundColor(.secondary)
    }
    .padding(.vertical, 2)
  }
}
