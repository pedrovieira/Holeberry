import SwiftUI

enum SettingsTab: String, CaseIterable {
  case server = "Server"
  case defaults = "Defaults"
  case advanced = "Advanced"

  var icon: String {
    switch self {
    case .server: return "server.rack"
    case .defaults: return "slider.horizontal.3"
    case .advanced: return "gearshape.2"
    }
  }
}

struct SettingsView: View {
  @AppStorage("serverURL")
  private var serverURL = ""
  @AppStorage("serverVersion")
  private var serverVersionRaw = PiholeServer.Version.autoDetect.rawValue
  @AppStorage("recentBlockedCount")
  private var recentBlockedCount = 20
  @AppStorage("maxActiveUnblocks")
  private var maxActiveUnblocks = 10
  @AppStorage("trustSelfSigned")
  private var trustSelfSigned = false

  @State private var password: String = ""
  @State private var testResultMessage: String = ""
  @State private var showTestResult: Bool = false
  @State private var selectedTab: SettingsTab = .server

  private let keychain = KeychainManager.shared

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
      }
    }
    .frame(width: 580, height: 400)
    .onAppear(perform: loadPassword)
    .onDisappear(perform: savePassword)
    .alert("Connection Test", isPresented: $showTestResult) {
      Button("OK") {}
    } message: {
      Text(testResultMessage)
    }
  }

  private var serverSection: some View {
    Section("Server") {
      TextField("URL (e.g. http://192.168.1.100:80)", text: $serverURL)
        .textFieldStyle(.roundedBorder)
        .labelsHidden()
        .help("The full URL to your Pi-hole instance including port")

      Picker("Version", selection: $serverVersionRaw) {
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
        TextField("", value: $recentBlockedCount, format: .number)
          .textFieldStyle(.roundedBorder)
          .frame(width: 70)
      }

      HStack {
        Text("Max active unblocks")
        Spacer()
        TextField("", value: $maxActiveUnblocks, format: .number)
          .textFieldStyle(.roundedBorder)
          .frame(width: 70)
      }
    }
  }

  private var advancedSection: some View {
    Section("Advanced") {
      Toggle("Trust self-signed certificates", isOn: $trustSelfSigned)
    }
  }

  private var testConnectionSection: some View {
    Section {
      Button("Test Connection", action: testConnection)
        .disabled(serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
  }

  private func loadPassword() {
    let url = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !url.isEmpty else { return }
    password = (try? keychain.readPassword(for: url)) ?? ""
  }

  private func savePassword() {
    let url = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
    if password.isEmpty {
      try? keychain.deletePassword(for: url)
    } else {
      try? keychain.savePassword(password, for: url)
    }
  }

  private func testConnection() {
    let url = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)

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

    let versionLabel = PiholeServer.Version(rawValue: serverVersionRaw)?.displayName ?? "Auto-detect"
    testResultMessage = """
      URL: \(url)
      Version: \(versionLabel)
      Password: Set

      Full connectivity test will be available after setting up the network layer.
      """
    showTestResult = true
  }
}
