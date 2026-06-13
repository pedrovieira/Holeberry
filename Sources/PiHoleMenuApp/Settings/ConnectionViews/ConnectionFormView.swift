import SwiftUI

struct ConnectionFormView: View {
  enum Mode {
    case add
    case edit(PiholeServer)
  }

  let mode: Mode
  var serverCount: Int = 0
  let onSave:
    (_ label: String?, _ url: String, _ credential: String, _ version: PiholeServer.Version?) async throws -> Void
  let onCancel: () -> Void

  @State private var label: String = ""
  @State private var url: String = ""
  @State private var credential: String = ""
  @State private var isCreating = false
  @State private var createError: String?
  @State private var createTask: Task<Void, Never>?
  @State private var didSaveToKeychain = false
  @State private var createdServerID: UUID?
  @State private var showingCredentialInfo = false

  private var hasURLError: Bool {
    !isCreating && !url.isEmpty && !isValidURL
  }

  private var isValidURL: Bool {
    let trimmed = url.trimmingCharacters(in: .whitespaces)
    return URL(string: trimmed)?.host?.isEmpty == false
  }

  private var canCreate: Bool {
    let trimmedURL = url.trimmingCharacters(in: .whitespaces)
    return !trimmedURL.isEmpty && isValidURL && !credential.isEmpty && !isCreating
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
          .disabled(isCreating)
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
          .disabled(isCreating)
          .background(
            RoundedRectangle(cornerRadius: 5)
              .stroke(hasURLError ? Color.red : .clear, lineWidth: 1)
          )
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      HStack(spacing: 4) {
        Text("Credential")
          .frame(width: 85, alignment: .trailing)
        SecureField("", text: $credential)
          .textFieldStyle(.roundedBorder)
          .multilineTextAlignment(.leading)
          .labelsHidden()
          .frame(maxWidth: .infinity)
          .disabled(isCreating)

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

      if let error = createError {
        HStack(spacing: 4) {
          Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: 10))
            .foregroundColor(.red)
          Text(error)
            .font(.system(size: 11))
            .foregroundColor(.red)
            .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }

      HStack(spacing: 8) {
        Spacer()
        Button("Cancel", action: handleCancel)
          .font(.system(size: 12))
        Button(action: { Task { await createServer() } }) {
          if isCreating {
            ProgressView()
              .controlSize(.small)
              .scaleEffect(0.8)
          } else {
            Text("Create")
          }
        }
        .buttonStyle(.borderedProminent)
        .font(.system(size: 12))
        .disabled(!canCreate)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .onAppear {
      if case .edit(let server) = mode {
        label = server.label ?? ""
        url = server.url
      }
    }
  }

  private func handleCancel() {
    if let task = createTask {
      task.cancel()
      createTask = nil
    }
    if didSaveToKeychain, let id = createdServerID {
      let manager = PiholeServerManager()
      manager.revertAddServer(id: id)
      didSaveToKeychain = false
      createdServerID = nil
    }
    isCreating = false
    createError = nil
    onCancel()
  }

  private func createServer() async {
    isCreating = true
    createError = nil
    didSaveToKeychain = false
    createdServerID = nil

    let serverURL = normalizedURL(from: url)

    let task = Task {
      do {
        try await withThrowingTimeout(seconds: 10) {
          let manager = PiholeServerManager()
          let version = try await manager.testConnection(url: serverURL, credential: credential)
          try Task.checkCancellation()

          let server = PiholeServer(label: label, url: serverURL, version: version)
          try KeychainManager.shared.saveCredential(credential, for: server.id)
          didSaveToKeychain = true
          createdServerID = server.id
          try Task.checkCancellation()

          _ = try manager.addServerAfterTest(label: label, url: serverURL, version: version)

          try await onSave(
            label.trimmingCharacters(in: .whitespaces).isEmpty ? nil : label,
            serverURL,
            credential,
            version
          )
        }
      } catch is CancellationError {
        if didSaveToKeychain, let id = createdServerID {
          let manager = PiholeServerManager()
          manager.revertAddServer(id: id)
        }
        didSaveToKeychain = false
        createdServerID = nil
        isCreating = false
      } catch _ as TimeoutError {
        if didSaveToKeychain, let id = createdServerID {
          let manager = PiholeServerManager()
          manager.revertAddServer(id: id)
        }
        didSaveToKeychain = false
        createdServerID = nil
        createError = "Creation failed. Timed out (10s)"
        isCreating = false
      } catch {
        if didSaveToKeychain, let id = createdServerID {
          let manager = PiholeServerManager()
          manager.revertAddServer(id: id)
        }
        didSaveToKeychain = false
        createdServerID = nil
        createError = "Creation failed: \(error.localizedDescription)"
        isCreating = false
      }
    }
    createTask = task
    await task.value
  }
}

struct TimeoutError: Error, LocalizedError {
  var errorDescription: String? { "Timed out" }
}

func withThrowingTimeout<T>(seconds: TimeInterval, operation: @escaping () async throws -> T) async throws -> T {
  try await withThrowingTaskGroup(of: T.self) { group in
    group.addTask {
      try await operation()
    }
    group.addTask {
      try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
      throw TimeoutError()
    }
    guard let result = try await group.next() else {
      throw TimeoutError()
    }
    group.cancelAll()
    return result
  }
}

func normalizedURL(from urlString: String) -> String {
  let trimmed = urlString.trimmingCharacters(in: .whitespaces)
  let suffixes = ["/admin/login/", "/admin/login", "/admin/", "/admin", "/"]
  var result = trimmed
  for suffix in suffixes where result.hasSuffix(suffix) {
    result = String(result.dropLast(suffix.count))
    break
  }
  return result
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
