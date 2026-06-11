import OSLog
import ServiceManagement
import SwiftUI

enum SettingsTab: String, CaseIterable {
  case server = "Server"
  case defaults = "Defaults"
  case advanced = "Advanced"
  case notifications = "Notifications"
  case about = "About"

  var icon: String {
    switch self {
    case .server: return "server.rack"
    case .defaults: return "slider.horizontal.3"
    case .advanced: return "gearshape.2"
    case .notifications: return "bell"
    case .about: return "info.circle"
    }
  }
}

struct SettingsView: View {
  @StateObject private var settings = SettingsStore()

  @State private var password: String = ""
  @State private var testResultMessage: String = ""
  @State private var showTestResult: Bool = false
  @State private var isToggling = false
  @State private var requiresApproval = false
  @State private var selectedTab: SettingsTab = .server

  private let keychain = KeychainManager.shared
  private let logger = Logger(subsystem: "com.pihole.menuapp", category: "settings")

  var body: some View {
    NavigationSplitView {
      List(SettingsTab.allCases, id: \.self, selection: $selectedTab) { tab in
        Label(tab.rawValue, systemImage: tab.icon)
      }
      .listStyle(.sidebar)
    } detail: {
      switch selectedTab {
      case .server:
        Form {
          serverSection
          testConnectionSection
        }
        .formStyle(.grouped)
      case .defaults:
        Form { defaultsSection }
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
    .frame(width: 580, height: 400)
    .onAppear {
      loadPassword()
      syncLaunchAtLoginFromSystem()
    }
    .onDisappear(perform: savePassword)
    .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
      guard (notification.object as? NSWindow)?.identifier?.rawValue == "Settings" else { return }
      syncLaunchAtLoginFromSystem()
    }
    .onChange(of: settings.launchAtLogin) { _, newValue in
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
        settings.launchAtLogin = !newValue
        requiresApproval = SMAppService.mainApp.status == .requiresApproval
      }
    }
    .alert("Connection Test", isPresented: $showTestResult) {
      Button("OK") {}
    } message: {
      Text(testResultMessage)
    }
  }

  private var serverSection: some View {
    Section("Server") {
      TextField("URL (e.g. http://192.168.1.100:80)", text: $settings.serverURL)
        .textFieldStyle(.roundedBorder)
        .labelsHidden()
        .help("The full URL to your Pi-hole instance including port")

      Picker("Version", selection: $settings.serverVersionRaw) {
        ForEach(PiholeServer.Version.allCases, id: \.rawValue) { version in
          Text(version.displayName).tag(version.rawValue)
        }
      }

      SecureField("Password / API Token", text: $password)
        .textFieldStyle(.roundedBorder)
        .labelsHidden()
        .help("Pi-hole v6 password or v5 API token")
    }
  }

  private var defaultsSection: some View {
    Section("Defaults") {
      HStack {
        Text("Recent blocked count")
        Spacer()
        TextField("", value: $settings.recentBlockedCount, format: .number)
          .textFieldStyle(.roundedBorder)
          .frame(width: 70)
      }

      HStack {
        Text("Max active unblocks")
        Spacer()
        TextField("", value: $settings.maxActiveUnblocks, format: .number)
          .textFieldStyle(.roundedBorder)
          .frame(width: 70)
      }
    }
  }

  private var advancedSection: some View {
    Section("Advanced") {
      Toggle("Trust self-signed certificates", isOn: $settings.trustSelfSigned)

      VStack(alignment: .leading) {
        Toggle("Launch at login", isOn: $settings.launchAtLogin)
          .disabled(isToggling)

        Text("Automatically start Pi-hole Menu when you log in to your Mac.")
          .font(.callout)
          .foregroundColor(.secondary)
      }

      if settings.launchAtLogin {
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
    }
  }

  private var testConnectionSection: some View {
    Section {
      Button("Test Connection", action: testConnection)
        .disabled(settings.serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
  }

  @ViewBuilder
  private var aboutView: some View {
    Form {
      Section("About PiHole Menu") {
        HStack {
          Label("Version", systemImage: "info.circle")
          Spacer()
          Text("1.0")
            .foregroundStyle(.secondary)
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
          socialButton(icon: "xmark", label: "X", url: "https://x.com/w1tch_")
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
          socialButton(icon: "globe", label: "Website", url: "https://pedrovieira.me")
          Spacer()
        }
      } header: {
        Text("Find me on")
          .frame(maxWidth: .infinity)
      }

      Section {
        Button {
          openURL("https://ko-fi.com/pedrovieiradev")
        } label: {
          Label("Donate on Ko-Fi", systemImage: "cup.and.saucer")
        }
      }
    }
    .formStyle(.grouped)
  }

  private func openURL(_ string: String) {
    guard let url = URL(string: string) else { return }
    NSWorkspace.shared.open(url)
  }

  private func socialButton(icon: String, label: String, url: String) -> some View {
    Button {
      guard let url = URL(string: url) else { return }
      NSWorkspace.shared.open(url)
    } label: {
      VStack(spacing: 4) {
        Image(systemName: icon)
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

  private func loadPassword() {
    let url = settings.serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !url.isEmpty else { return }
    password = (try? keychain.readPassword(for: url)) ?? ""
  }

  private func savePassword() {
    let url = settings.serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
    if password.isEmpty {
      try? keychain.deletePassword(for: url)
    } else {
      try? keychain.savePassword(password, for: url)
    }
  }

  private func syncLaunchAtLoginFromSystem() {
    settings.launchAtLogin = SMAppService.mainApp.status == .enabled
    requiresApproval = SMAppService.mainApp.status == .requiresApproval
  }

  private func testConnection() {
    let url = settings.serverURL.trimmingCharacters(in: .whitespacesAndNewlines)

    guard !url.isEmpty else {
      testResultMessage = "Please enter a server URL first."
      showTestResult = true
      return
    }

    guard URL(string: url) != nil else {
      testResultMessage = "Invalid URL format. Expected format: http://host:port"
      showTestResult = true
      return
    }

    guard !password.isEmpty else {
      testResultMessage = "Password or API token is required."
      showTestResult = true
      return
    }

    savePassword()

    let versionLabel = PiholeServer.Version(rawValue: settings.serverVersionRaw)?.displayName ?? "Auto-detect"
    testResultMessage = """
      URL: \(url)
      Version: \(versionLabel)
      Password: Set

      Full connectivity test will be available after setting up the network layer.
      """
    showTestResult = true
  }
}
