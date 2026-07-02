import SwiftUI

// MARK: - Sheet Mode

enum SheetMode: Identifiable {
  case add(prefillURL: String? = nil)
  case edit(ServerConfig)

  var id: String {
    switch self {
    case .add: return "add"
    case .edit: return "edit"
    }
  }

  var prefillURL: String {
    switch self {
    case .add(let prefill): return prefill ?? ""
    case .edit(let config): return config.url
    }
  }

  var existingLabel: String? {
    if case .edit(let config) = self { return config.label }
    return nil
  }
}

// MARK: - Connection Sheet

struct ConnectionSheet: View {
  let mode: SheetMode
  var serverCount: Int = 0
  let onDismiss: () -> Void
  let onCancel: () -> Void

  let serverManager: PiholeServerManager

  @State private var label: String = ""
  @State private var url: String = ""
  @State private var credential: String = ""
  @State private var isCreating = false
  @State private var createError: String?
  @State private var showingCredentialInfo = false
  @State private var isTotpError = false
  @State private var shakeTrigger: Int = 0

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
    VStack(spacing: 12) {
      Text(isAdd ? "New Connection" : "Edit Connection")
        .font(.headline)

      Divider()

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

        HStack(spacing: 4) {
          Text("Instance URL")
            .frame(width: 85, alignment: .trailing)
          TextField("", text: $url)
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.leading)
            .labelsHidden()
            .frame(maxWidth: .infinity)
            .autocorrectionDisabled()
            .textContentType(.URL)
            .disabled(isCreating)
            .background(
              RoundedRectangle(cornerRadius: 5)
                .stroke(hasURLError ? Color.red : .clear, lineWidth: 1)
            )
            .onChange(of: url) {
              if isTotpError {
                isTotpError = false
                createError = nil
              }
            }
        }

        HStack(spacing: 4) {
          Text("Credential")
            .frame(width: 85, alignment: .trailing)
          SecureField("", text: $credential)
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.leading)
            .labelsHidden()
            .frame(maxWidth: .infinity)
            .textContentType(.password)
            .disabled(isCreating)
            .onChange(of: credential) {
              if isTotpError {
                isTotpError = false
                createError = nil
              }
            }

          Button {
            showingCredentialInfo.toggle()
          } label: {
            Image(systemName: "info.circle")
              .font(.system(size: 14))
              .foregroundColor(.secondary)
          }
          .buttonStyle(.plain)
          .popover(isPresented: $showingCredentialInfo) {
            CredentialInfoPopover()
          }
        }
      }

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

      Divider()

      HStack(spacing: 8) {
        if isTotpError {
          Spacer()
          Button("Open Pi-hole Web UI") {
            let webURL = normalizedURL(from: url).trimmingCharacters(in: .whitespaces)
            if let nsURL = URL(string: webURL + "/admin") {
              NSWorkspace.shared.open(nsURL)
            }
          }
          Button("Cancel", action: handleCancel)
            .font(.system(size: 12))
        } else {
          Spacer()
          Button("Cancel", action: handleCancel)
            .font(.system(size: 12))
          Button {
            Task { await submit() }
          } label: {
            if isCreating {
              ProgressView()
                .controlSize(.small)
                .scaleEffect(0.8)
            } else {
              Text(isAdd ? "Create" : "Update")
            }
          }
          .buttonStyle(.borderedProminent)
          .font(.system(size: 12))
          .disabled(!canCreate)
        }
      }
    }
    .padding(20)
    .frame(width: 420)
    .phaseAnimator(
      [0, -10, 10, -6, 6, -3, 3, 0],
      trigger: shakeTrigger
    ) { content, offset in
      content.offset(x: offset)
    } animation: { _ in
      .linear(duration: 0.4)
    }
    .onAppear {
      url = mode.prefillURL
      if let existingLabel = mode.existingLabel {
        label = existingLabel
      }
    }
  }

  private var isAdd: Bool {
    if case .add = mode { return true }
    return false
  }

  private func handleCancel() {
    isCreating = false
    createError = nil
    onCancel()
  }

  private func submit() async {
    isCreating = true
    createError = nil

    let serverURL = normalizedURL(from: url)
    let trimmedLabel = label.trimmingCharacters(in: .whitespaces).isEmpty ? nil : label

    if isAdd {
      do {
        try await withThrowingTimeout(seconds: 10) {
          _ = try await serverManager.addServer(
            label: trimmedLabel, url: serverURL, credential: credential
          )
        }
        onDismiss()
      } catch is CancellationError {
        isCreating = false
      } catch _ as TimeoutError {
        createError = "Creation failed. Timed out (10s)"
        triggerShake()
        isCreating = false
      } catch PiholeError.totpRequired {
        createError = "Your Pi-hole uses TOTP. Create an Application Password in the web UI and use it here."
        isTotpError = true
        triggerShake()
        isCreating = false
      } catch {
        createError = "Creation failed: \(error.localizedDescription)"
        triggerShake()
        isCreating = false
      }
    } else {
      guard case .edit(let server) = mode else { return }
      serverManager.updateServer(
        id: server.id,
        label: trimmedLabel,
        url: serverURL,
        credential: credential.isEmpty ? nil : credential
      )
      onDismiss()
    }
  }

  private func triggerShake() {
    withAnimation {
      shakeTrigger += 1
    }
  }
}

// MARK: - Helpers (moved from ConnectionFormView)

struct TimeoutError: Error, LocalizedError {
  var errorDescription: String? { "Timed out" }
}

func withThrowingTimeout<T: Sendable>(
  seconds: TimeInterval,
  operation: @escaping @Sendable () async throws -> T
) async throws -> T {
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
