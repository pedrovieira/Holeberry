import SwiftUI

struct ConnectionFormView: View {
  enum Mode {
    case add
    case edit(PiholeServer)
  }

  let mode: Mode
  var serverCount: Int = 0
  let onSave:
    (_ label: String?, _ url: String, _ password: String, _ version: PiholeServer.Version?) async throws -> Void
  let onCancel: () -> Void

  @State private var label: String = ""
  @State private var url: String = ""
  @State private var password: String = ""
  @State private var isTesting = false
  @State private var testPassed = false
  @State private var testError: String?
  @State private var detectedVersion: PiholeServer.Version?
  @State private var isSaving = false
  @State private var showingCredentialInfo = false

  private var isValidURL: Bool {
    let trimmed = url.trimmingCharacters(in: .whitespaces)
    return URL(string: trimmed)?.host?.isEmpty == false
  }

  private var saveEnabled: Bool {
    guard !url.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
    if case .edit(let server) = mode, url == server.url, password == "" {
      return true
    }
    return testPassed && !isSaving
  }

  var body: some View {
    VStack(spacing: 8) {
      HStack(spacing: 4) {
        Text("Label")
          .frame(width: 85, alignment: .trailing)
        TextField("", text: $label, prompt: Text("Instance \(serverCount + 1)"))
          .textFieldStyle(.roundedBorder)
          .multilineTextAlignment(.leading)
          .labelsHidden()
          .frame(maxWidth: .infinity)
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      HStack(spacing: 4) {
        Text("Instance URL")
          .frame(width: 85, alignment: .trailing)
        TextField("", text: $url)
          .textFieldStyle(.roundedBorder)
          .multilineTextAlignment(.leading)
          .labelsHidden()
          .frame(maxWidth: .infinity)
          .autocorrectionDisabled()
          .background(
            RoundedRectangle(cornerRadius: 5)
              .stroke(!url.isEmpty && !isValidURL ? Color.red : .clear, lineWidth: 1)
          )
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      HStack(spacing: 4) {
        Text("Credential")
          .frame(width: 85, alignment: .trailing)
        SecureField("", text: $password)
          .textFieldStyle(.roundedBorder)
          .multilineTextAlignment(.leading)
          .labelsHidden()
          .frame(maxWidth: .infinity)

        Button(action: { showingCredentialInfo.toggle() }) {
          Image(systemName: "info.circle")
            .font(.system(size: 14))
            .foregroundColor(.secondary)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingCredentialInfo) {
          CredentialInfoPopover()
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      if let error = testError {
        Text(error)
          .font(.system(size: 11))
          .foregroundColor(.red)
          .frame(maxWidth: .infinity)
      }

      HStack(spacing: 8) {
        Button("Test Connection") {
          Task { await runTest() }
        }
        .disabled(url.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty || isTesting)
        .font(.system(size: 11))

        Button("Save") {
          Task { await save() }
        }
        .disabled(!saveEnabled)
        .font(.system(size: 11))
      }

      Button("Cancel", action: onCancel)
        .buttonStyle(.plain)
        .font(.system(size: 10))
        .foregroundColor(.secondary)
        .frame(maxWidth: .infinity)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .onAppear {
      if case .edit(let server) = mode {
        label = server.label ?? ""
        url = server.url
        detectedVersion = server.version
        if server.version != nil {
          testPassed = true
        }
      }
    }
  }

  private func runTest() async {
    isTesting = true
    testError = nil
    testPassed = false
    detectedVersion = nil

    do {
      let manager = PiholeServerManager()
      let version = try await manager.testConnection(url: url, credential: password)
      detectedVersion = version
      testPassed = true
    } catch {
      testError = "Connection failed: \(error.localizedDescription)"
    }

    isTesting = false
  }

  private func save() async {
    isSaving = true
    defer { isSaving = false }

    do {
      let trimmedLabel = label.trimmingCharacters(in: .whitespaces)
      let trimmedURL = url.trimmingCharacters(in: .whitespaces)
      try await onSave(
        trimmedLabel.isEmpty ? nil : trimmedLabel,
        trimmedURL,
        password,
        detectedVersion
      )
    } catch {
      testError = "Save failed: \(error.localizedDescription)"
    }
  }
}

struct CredentialInfoPopover: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Credential Information")
        .font(.system(size: 12, weight: .semibold))

      Group {
        Text("Pi-hole v5:")
          .font(.system(size: 11, weight: .semibold))
        Text("Use your API token from Pi-hole Admin Console → Settings → API → Show API token.")
          .font(.system(size: 10))
          .foregroundColor(.secondary)

        Text("Pi-hole v6:")
          .font(.system(size: 11, weight: .semibold))
        Text("Use your web interface password. The app handles session-based auth automatically.")
          .font(.system(size: 10))
          .foregroundColor(.secondary)
      }
    }
    .padding(12)
    .frame(width: 240)
  }
}
