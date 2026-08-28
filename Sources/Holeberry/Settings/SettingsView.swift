import Defaults
import HoleberryCore
import KeyboardShortcuts
import OSLog
import ServiceManagement
import Sparkle
import SwiftUI

// swiftlint:disable file_length

enum SettingsTab: String, CaseIterable {
  case servers = "Servers"
  case defaults = "General"
  case durations = "Durations"
  case shortcuts = "Shortcuts"
  case notifications = "Notifications"
  case about = "About"

  var image: Image {
    switch self {
    case .servers: return Image("Pi-hole")
    case .defaults: return Image(systemName: "slider.horizontal.3")
    case .durations: return Image(systemName: "timer")
    case .shortcuts: return Image(systemName: "keyboard")
    case .notifications: return Image(systemName: "bell")
    case .about: return Image(systemName: "info.circle")
    }
  }
}

struct SettingsView: View {
  @Default var launchAtLogin: Bool
  @Default var browserTabUnblockEnabled: Bool
  @Default var showAllClientsRecentBlocked: Bool
  @Default var showPerInstanceStats: Bool
  @Default var showGravityMenuItem: Bool
  @Default var durations: [UnblockDurationEntry]
  @Default var unblockCurrentTabDuration: UnblockCurrentTabDurationSelection

  @State private var isToggling = false
  @State private var requiresApproval = false
  @State private var selectedTab: SettingsTab

  let serverManager: PiholeServerManager
  let updater: SPUUpdater?
  let discoveryService: PiholeDiscoveryService
  let statusPoller: ServerStatusPoller
  let notificationCoordinator: NotificationCoordinator

  private let logger = Logger(subsystem: Logger.appSubsystem, category: "settings")

  private let defaultsSuite: UserDefaults

  init(
    serverManager: PiholeServerManager,
    initialTab: SettingsTab = .servers,
    updater: SPUUpdater? = nil,
    defaultsSuite: UserDefaults = .standard,
    discoveryService: PiholeDiscoveryService,
    statusPoller: ServerStatusPoller,
    notificationCoordinator: NotificationCoordinator
  ) {
    self.serverManager = serverManager
    self.updater = updater
    self.discoveryService = discoveryService
    self.statusPoller = statusPoller
    self.notificationCoordinator = notificationCoordinator
    self.defaultsSuite = defaultsSuite
    _launchAtLogin = .init(.launchAtLogin(suite: defaultsSuite))
    _browserTabUnblockEnabled = .init(.browserTabUnblockEnabled(suite: defaultsSuite))
    _showAllClientsRecentBlocked = .init(.showAllClientsRecentBlocked(suite: defaultsSuite))
    _showPerInstanceStats = .init(.showPerInstanceStats(suite: defaultsSuite))
    _showGravityMenuItem = .init(.showGravityMenuItem(suite: defaultsSuite))
    _durations = .init(.unblockDurations(suite: defaultsSuite))
    _unblockCurrentTabDuration = .init(.unblockCurrentTabDuration(suite: defaultsSuite))
    _selectedTab = State(initialValue: initialTab)
  }

  var body: some View {
    NavigationSplitView {
      List(SettingsTab.allCases, id: \.self, selection: $selectedTab) { tab in
        Label {
          Text(tab.rawValue)
        } icon: {
          tab.image
            .resizable()
            .scaledToFit()
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
          ConnectionListView(
            serverManager: serverManager,
            discoveryService: discoveryService,
            statusPoller: statusPoller
          )
        }
        .formStyle(.grouped)
      case .defaults:
        Form { generalSection }
          .formStyle(.grouped)
      case .shortcuts:
        Form { shortcutsSection }
          .formStyle(.grouped)
      case .durations:
        Form { DurationsSettingsView(defaultsSuite: defaultsSuite) }
          .formStyle(.grouped)
      case .notifications:
        Form {
          NotificationsSettingsView(
            defaultsSuite: defaultsSuite,
            notificationCoordinator: notificationCoordinator
          )
        }
        .formStyle(.grouped)
      case .about:
        aboutView
      }
    }
    .navigationSplitViewStyle(.balanced)
    .toolbar {
      if let updater {
        ToolbarItem(placement: .automatic) {
          CheckForUpdatesView(updater: updater)
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
    .frame(width: 580, height: 520)
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

  @ViewBuilder private var generalSection: some View {
    Section("General") {
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

      VStack(alignment: .leading) {
        Toggle("Show per-instance queries/blocked statuses", isOn: $showPerInstanceStats)

        Text("Only applies when you have 2 instances connected.")
          .font(.callout)
          .foregroundColor(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }

    Section("Gravity") {
      Toggle("Show Gravity on main menu", isOn: $showGravityMenuItem)
    }

    BrowserTabSettingsView(isEnabled: $browserTabUnblockEnabled)

    Section("Recently Blocked") {
      VStack(alignment: .leading) {
        Toggle("Show recently blocked for all clients", isOn: $showAllClientsRecentBlocked)

        (Text("Show blocked domains from all network devices. ")
          + Text("This Mac's blocks are marked with ")
          + Text(Image(systemName: "person.circle"))
          + Text("."))
          .font(.callout)
          .foregroundColor(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  @ViewBuilder
  private var shortcutsSection: some View {
    Section {
      KeyboardShortcuts.Recorder("Re-enable Blocking:", name: .reEnableBlocking)

      VStack(alignment: .leading) {
        LabeledContent {
          ShortcutRecorder(name: .unblockCurrentTab)
            .disabled(!browserTabUnblockEnabled)
        } label: {
          Text("Unblock Current Tab:")
        }

        UnblockCurrentTabDurationPicker(durations: $durations, selection: $unblockCurrentTabDuration)
          .disabled(!browserTabUnblockEnabled)

        if !browserTabUnblockEnabled {
          Button("Enable browser tab unblocking in General to use this shortcut.") { selectedTab = .defaults }
            .buttonStyle(.link)
            .font(.callout)
            .padding(.top, 5)
        }
      }

      KeyboardShortcuts.Recorder("Update Gravity:", name: .updateGravity)
    } header: {
      Text("Global Shortcuts")
      Text(
        """
        Shortcuts work globally even when the app is in the background. \
        Press Escape in a recorder to clear a shortcut.
        """
      )
      .font(.subheadline)
      .foregroundStyle(.secondary)
    }

    Section {
      ForEach(durations) { entry in
        KeyboardShortcuts.Recorder(
          "Disable \(UnblockDurationFormatter.string(from: entry.seconds)):",
          name: KeyboardShortcuts.Name.durationShortcutName(for: entry)
        )
      }
      KeyboardShortcuts.Recorder("Disable Indefinitely:", name: .disableIndefinitely)
      KeyboardShortcuts.Recorder("Custom duration...:", name: .disableCustom)
    } header: {
      Text("Unblock Durations")
      Text("Synced with the durations configured in the Durations tab.")
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
  }

  /// Wraps `KeyboardShortcuts.RecorderCocoa` so SwiftUI's `.disabled` state
  /// actually propagates to the underlying `NSSearchField` (the library's
  /// `Recorder` view does not read `isEnabled` from the environment).
  private struct ShortcutRecorder: NSViewRepresentable {
    let name: KeyboardShortcuts.Name

    @Environment(\.isEnabled) private var isEnabled

    func makeNSView(context: Context) -> KeyboardShortcuts.RecorderCocoa {
      KeyboardShortcuts.RecorderCocoa(for: name)
    }

    func updateNSView(_ nsView: KeyboardShortcuts.RecorderCocoa, context: Context) {
      nsView.isEnabled = isEnabled
    }
  }

  @ViewBuilder private var aboutView: some View {
    Form {
      Section("About Holeberry") {
        HStack {
          Label("Version", systemImage: "info.circle")
          Spacer()
          if let version = Bundle.main.releaseVersionNumber {
            Text(version)
              .foregroundStyle(.secondary)
          }
        }

        if let updater {
          UpdaterSettingsView(updater: updater)
        }
      }

      Section {
        HStack(spacing: 30) {
          Spacer(minLength: 0)
          Button {
            openURL("https://github.com/pedrovieira/Holeberry")
          } label: {
            VStack(spacing: 5) {
              Image("Github")
                .resizable()
                .scaledToFit()
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
                .scaledToFit()
                .frame(width: 16, height: 16)
              Text("GitHub")
                .font(.caption2)
            }
            .contentShape(Rectangle())
          }
          .buttonStyle(PlainButtonStyle())
          socialButton(icon: Image(systemName: "globe"), label: "Website", url: "https://holeberryapp.com/")
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

      Section {
      } footer: {
        Text(
          "Pi-hole® is a registered trademark of Pi-hole LLC. "
            + "Holeberry is an independent project and is not affiliated with Pi-hole LLC."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
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
          .scaledToFit()
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
