import Defaults
import KeyboardShortcuts
import OSLog
import ServiceManagement
import SwiftUI

enum SettingsTab: String, CaseIterable {
  case servers = "Servers"
  case defaults = "Defaults"
  case shortcuts = "Shortcuts"
  case advanced = "Advanced"
  case notifications = "Notifications"
  case about = "About"

  var image: Image {
    switch self {
    case .servers: return Image("Pi-hole")
    case .defaults: return Image(systemName: "slider.horizontal.3")
    case .shortcuts: return Image(systemName: "keyboard")
    case .advanced: return Image(systemName: "gearshape.2")
    case .notifications: return Image(systemName: "bell")
    case .about: return Image(systemName: "info.circle")
    }
  }
}

struct SettingsView: View {
  @Default(.recentBlockedCount)
  var recentBlockedCount
  @Default(.launchAtLogin)
  var launchAtLogin
  @Default(.browserTabUnblockEnabled)
  var browserTabUnblockEnabled

  @State private var isToggling = false
  @State private var requiresApproval = false
  @State private var selectedTab: SettingsTab = .servers

  let serverManager: PiholeServerManager

  private let logger = Logger(subsystem: Logger.appSubsystem, category: "settings")

  var body: some View {
    NavigationSplitView {
      List(SettingsTab.allCases, id: \.self, selection: $selectedTab) { tab in
        Label {
          Text(tab.rawValue)
        } icon: {
          tab.image
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 16, height: 16)
        }
      }
      .listStyle(.sidebar)
      .frame(minWidth: 145)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .navigationSplitViewColumnWidth(min: 140, ideal: 160, max: 160)
    } detail: {
      switch selectedTab {
      case .servers:
        Form {
          ConnectionListView(serverManager: serverManager)
        }
        .formStyle(.grouped)
      case .defaults:
        Form { defaultsSection }
          .formStyle(.grouped)
      case .shortcuts:
        Form { shortcutsSection }
          .formStyle(.grouped)
      case .advanced:
        Form { advancedSection }
          .formStyle(.grouped)
      case .notifications:
        Form {
          Section("Notifications") {
            Label("Notify on block", systemImage: "bell")
          }
        }
        .formStyle(.grouped)
      case .about:
        aboutView
      }
    }
    .navigationSplitViewStyle(.balanced)
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button("Quit App") {
          NSApplication.shared.terminate(nil)
        }
      }
    }
    .background {
      ZStack {
        Color(NSColor.windowBackgroundColor)
        RoundedRectangle(cornerRadius: 18, style: .continuous)
          .fill(.ultraThinMaterial)
      }
      .ignoresSafeArea()
    }
    .frame(width: 580, height: 420)
    .onAppear {
      syncLaunchAtLoginFromSystem()
    }
    .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
      guard (notification.object as? NSWindow)?.identifier?.rawValue == "Settings" else { return }
      syncLaunchAtLoginFromSystem()
    }
    .onChange(of: launchAtLogin) { _, newValue in
      guard !isToggling else { return }
      isToggling = true
      defer { isToggling = false }
      do {
        if newValue {
          try SMAppService.mainApp.register()
        } else {
          try SMAppService.mainApp.unregister()
        }
        requiresApproval = SMAppService.mainApp.status == .requiresApproval
      } catch {
        logger.error("Failed to update login item: \(error.localizedDescription, privacy: .public)")
        launchAtLogin = !newValue
        requiresApproval = SMAppService.mainApp.status == .requiresApproval
      }
    }
  }

  private var defaultsSection: some View {
    Section("Defaults") {
      HStack {
        Text("Recent blocked count")
        Spacer()
        TextField("", value: $recentBlockedCount, format: .number)
          .textFieldStyle(.roundedBorder)
          .frame(width: 70)
      }
    }
  }

  private var shortcutsSection: some View {
    Section {
      KeyboardShortcuts.Recorder("Disable Indefinitely:", name: .disableIndefinitely)
      KeyboardShortcuts.Recorder("Disable 10 seconds:", name: .disable10s)
      KeyboardShortcuts.Recorder("Disable 30 seconds:", name: .disable30s)
      KeyboardShortcuts.Recorder("Disable 5 minutes:", name: .disable5m)
      KeyboardShortcuts.Recorder("Custom duration...:", name: .disableCustom)
      KeyboardShortcuts.Recorder("Re-enable Blocking:", name: .reEnableBlocking)
    } header: {
      Text("Global Shortcuts")
    } footer: {
      Text(
        """
        Shortcuts work globally even when the app is in the background. \
        Press Escape in a recorder to clear a shortcut.
        """
      )
      .foregroundStyle(.secondary)
    }
  }

  private var advancedSection: some View {
    Section("Advanced") {
      VStack(alignment: .leading) {
        Toggle("Launch at login", isOn: $launchAtLogin)
          .disabled(isToggling)

        Text("Automatically start Holeberry when you log in to your Mac.")
          .font(.callout)
          .foregroundColor(.secondary)
      }

      if launchAtLogin {
        HStack(spacing: 4) {
          if requiresApproval {
            Text("Approval needed —")
              .font(.caption)
              .foregroundColor(.secondary)
          }
          Button("System Settings > General > Login Items") {
            SMAppService.openSystemSettingsLoginItems()
          }
          .buttonStyle(.plain)
          .controlSize(.small)
          .foregroundColor(.accentColor)
        }
      }

      Divider()
        .padding(.vertical, 4)

      VStack(alignment: .leading) {
        Toggle("Enable browser tab unblocking", isOn: $browserTabUnblockEnabled)

        Text("Let Holeberry read the current browser tab URL to quickly unblock it. Requires Automation permission.")
          .font(.callout)
          .foregroundColor(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      if browserTabUnblockEnabled {
        KeyboardShortcuts.Recorder("Unblock Current Tab:", name: .unblockCurrentTab)
      }
    }
  }

  @ViewBuilder private var aboutView: some View {
    Form {
      Section("About Holeberry") {
        HStack {
          Label("Version", systemImage: "info.circle")
          Spacer()
          if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            Text(version)
              .foregroundStyle(.secondary)
          }
        }
      }

      Section {
        HStack(spacing: 30) {
          Spacer(minLength: 0)
          Button {
            openURL("https://github.com/pedrovieira/pihole-bar")
          } label: {
            VStack(spacing: 5) {
              Image("Github")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 18)
              Text("GitHub")
            }
            .contentShape(Rectangle())
          }
          .buttonStyle(PlainButtonStyle())
          Spacer(minLength: 0)
        }
      }

      Section {
        HStack(spacing: 24) {
          Spacer()
          socialButton(icon: Image("X"), label: "X", url: "https://x.com/w1tch_")
          Button {
            openURL("https://github.com/pedrovieira")
          } label: {
            VStack(spacing: 4) {
              Image("Github")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 16, height: 16)
              Text("GitHub")
                .font(.caption2)
            }
            .contentShape(Rectangle())
          }
          .buttonStyle(PlainButtonStyle())
          socialButton(icon: Image(systemName: "globe"), label: "Website", url: "https://pedrovieira.me")
          Spacer()
        }
      } header: {
        Text("Find me on")
          .frame(maxWidth: .infinity)
      }

      Section {}

      Section {
        HStack(spacing: 30) {
          Spacer(minLength: 0)
          VStack(spacing: 8) {
            Text("Buy me a coffee! ☕️")
              .foregroundStyle(.secondary)
            Button {
              openURL("https://ko-fi.com/pedrovieiradev")
            } label: {
              Text("Donate")
            }
            .controlSize(.large)
          }
          Spacer(minLength: 0)
        }
      }
    }
    .formStyle(.grouped)
  }

  private func openURL(_ string: String) {
    guard let url = URL(string: string) else { return }
    NSWorkspace.shared.open(url)
  }

  private func socialButton(icon: Image, label: String, url: String) -> some View {
    Button {
      openURL(url)
    } label: {
      VStack(spacing: 4) {
        icon
          .resizable()
          .aspectRatio(contentMode: .fit)
          .frame(width: 16, height: 16)
        Text(label)
          .font(.caption2)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(PlainButtonStyle())
  }

  private func syncLaunchAtLoginFromSystem() {
    launchAtLogin = SMAppService.mainApp.status == .enabled
    requiresApproval = SMAppService.mainApp.status == .requiresApproval
  }
}
