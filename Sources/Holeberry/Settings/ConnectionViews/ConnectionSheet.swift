import HoleberryCore
import SwiftUI
import SymbolPicker

// swiftlint:disable file_length

// MARK: - Sheet Mode

enum SheetMode: Identifiable, Equatable {
  case add(prefillURL: String? = nil)
  case edit(ServerConfig)
  case reauthenticate(ServerConfig)

  var id: String {
    switch self {
    case .add: return "add"
    case .edit: return "edit"
    case .reauthenticate: return "reauthenticate"
    }
  }

  var prefillURL: String {
    switch self {
    case .add(let prefill): return prefill ?? ""
    case .edit(let config): return config.url
    case .reauthenticate(let config): return config.url
    }
  }

  var existingLabel: String? {
    switch self {
    case .edit(let config): return config.label
    case .reauthenticate(let config): return config.label
    case .add: return nil
    }
  }

  var existingIcon: String? {
    if case .edit(let config) = self { return config.icon }
    return nil
  }
}

public struct ShakeEffect: GeometryEffect {
  private let amount: CGFloat = 10.0
  private let shakesPerUnit: CGFloat = 3.0
  public var animatableData: CGFloat
  public init(animatableData: CGFloat) {
    self.animatableData = animatableData
  }

  public func effectValue(size: CGSize) -> ProjectionTransform {
    ProjectionTransform(
      CGAffineTransform(
        translationX: self.amount * sin(self.animatableData * .pi * self.shakesPerUnit),
        y: 0.0
      )
    )
  }
}

// MARK: - Connection Sheet

struct ConnectionSheet: View {
  let mode: SheetMode
  var serverCount: Int = 0
  let onDismiss: () -> Void
  let onCancel: () -> Void

  let serverManager: PiholeServerManager

  init(
    mode: SheetMode,
    serverCount: Int = 0,
    onDismiss: @escaping () -> Void,
    onCancel: @escaping () -> Void,
    serverManager: PiholeServerManager
  ) {
    self.mode = mode
    self.serverCount = serverCount
    self.onDismiss = onDismiss
    self.onCancel = onCancel
    self.serverManager = serverManager
    _label = State(initialValue: mode.existingLabel ?? "")
    _iconName = State(initialValue: mode.existingIcon ?? "")
    if case .edit(let config) = mode {
      // No stored credential = password-less.
      hasStoredCredential = serverManager.hasStoredCredential(id: config.id)
    } else {
      hasStoredCredential = true
    }
  }

  @State private var label: String = ""
  @State private var generatedLabel: String = ""
  @State private var url: String = ""
  @State private var credential: String = ""
  /// Whether the server has a stored credential (edit mode).
  private let hasStoredCredential: Bool
  @State private var isCreating = false
  @State private var createError: String?
  @State private var showingCredentialInfo = false
  @State private var isTotpError = false
  @State private var shakeTrigger: CGFloat = 0
  @State private var iconName: String = ""
  @State private var showingIconPicker = false
  @FocusState private var credentialFocused: Bool

  /// Hard cap for the instance label; enforced live by `LimitedTextField` and
  /// defensively at save time.
  private static let labelMaxLength = 20

  private var hasURLError: Bool {
    !isCreating && !url.isEmpty && !isValidURL
  }

  private var isValidURL: Bool {
    let trimmed = url.trimmingCharacters(in: .whitespaces)
    return URL(string: trimmed)?.host?.isEmpty == false
  }

  private var canCreate: Bool {
    let trimmedURL = url.trimmingCharacters(in: .whitespaces)
    let baseValid = !trimmedURL.isEmpty && isValidURL && !isCreating
    if isReauthenticate || isAdd {
      // Empty credential = password-less; validated on connect.
      return baseValid
    }
    // Edit mode: require some change.
    let labelChanged = label != (mode.existingLabel ?? "")
    let iconChanged = iconName != (mode.existingIcon ?? "")
    let urlChanged = url.trimmingCharacters(in: .whitespaces) != mode.prefillURL
    return baseValid && (labelChanged || iconChanged || urlChanged || !credential.isEmpty)
  }

  var body: some View {
    VStack(spacing: 12) {
      Text(isAdd ? "New Connection" : (isReauthenticate ? "Re-authenticate" : "Edit Connection"))
        .font(.headline)

      Divider()

      iconCircleView

      VStack(spacing: 8) {
        HStack(spacing: 4) {
          Text("Label")
            .frame(width: 85, alignment: .trailing)
          LimitedTextField(
            text: $label,
            maxLength: Self.labelMaxLength,
            placeholder: generatedLabel,
            isEnabled: !isCreating
          ) {
            guard canCreate else { return }
            Task { await submit() }
          }
          .frame(maxWidth: .infinity)
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
            .disabled(isCreating || isReauthenticate)
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
          SecureField(hasStoredCredential ? "" : "No password required", text: $credential)
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.leading)
            .labelsHidden()
            .frame(maxWidth: .infinity)
            .textContentType(.password)
            .disabled(isCreating || !hasStoredCredential)
            .focused($credentialFocused)
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
        VStack(spacing: 4) {
          Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: 10))
            .foregroundColor(.red)
          Text(error)
            .font(.system(size: 11))
            .foregroundColor(.red)
            .multilineTextAlignment(.center)
            .lineLimit(2)
        }
        .frame(maxWidth: .infinity)
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
            Text(isReauthenticate ? "Re-authenticate" : (isAdd ? "Create" : "Update"))
              .opacity(isCreating ? 0 : 1)
              .overlay {
                if isCreating {
                  ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.8)
                }
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
    .modifier(ShakeEffect(animatableData: shakeTrigger))
    .onSubmit {
      guard canCreate else { return }
      Task { await submit() }
    }
    .onAppear {
      url = mode.prefillURL
      generatedLabel = isAdd ? WordLabel.generate() : (mode.existingLabel ?? "")
      if isReauthenticate {
        credentialFocused = true
      }
    }
  }

  private var iconCircleView: some View {
    ZStack {
      Button {
        showingIconPicker = true
      } label: {
        ZStack {
          if iconName.isEmpty {
            Color.clear
              .frame(width: 48, height: 48)

            Circle()
              .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
              .foregroundColor(.secondary.opacity(0.4))
              .frame(width: 48, height: 48)

            Image(systemName: "plus")
              .font(.system(size: 16, weight: .medium))
              .foregroundColor(.secondary.opacity(0.6))
          } else {
            Color.clear
              .frame(width: 48, height: 48)

            Circle()
              .fill(Color.accentColor.opacity(0.15))
              .frame(width: 48, height: 48)

            Image(systemName: iconName)
              .font(.system(size: 22))
              .foregroundColor(.accentColor)
          }
        }
        .contentShape(Circle())
      }
      .buttonStyle(.plain)
      .disabled(isCreating)
      .popover(isPresented: $showingIconPicker) {
        SymbolPicker(symbolName: $iconName)
          .symbolPickerSymbolsStyle(.filled)
          .symbolPickerDismiss(type: .onSymbolSelect) {
            showingIconPicker = false
          }
          .frame(width: 310, height: 430)
      }

      if !iconName.isEmpty {
        Button {
          iconName = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
            .font(.system(size: 14))
            .foregroundColor(.secondary)
            .background(Circle().fill(Color(nsColor: .windowBackgroundColor)))
        }
        .buttonStyle(.plain)
        .disabled(isCreating)
        .offset(x: 20, y: -20)
      }
    }
    .padding(.vertical, 4)
  }

  private func triggerShake() {
    withAnimation(.easeOut(duration: 0.45)) {
      shakeTrigger += 1
    }
  }

  private var isAdd: Bool {
    if case .add = mode { return true }
    return false
  }

  private var isReauthenticate: Bool {
    if case .reauthenticate = mode { return true }
    return false
  }

  private func handleCancel() {
    isCreating = false
    createError = nil
    onCancel()
  }

  private func submitReauthentication(server: ServerConfig, serverURL: String) async {
    let serverID = server.id
    do {
      let isPasswordless = try await withThrowingTimeout(seconds: 10) {
        try await serverManager.verifyCredential(id: serverID, credential: credential)
      }
      let serverLabel =
        label.isEmpty
        ? server.label.map { String($0.prefix(Self.labelMaxLength)) }
        : String(label.prefix(Self.labelMaxLength))
      serverManager.updateServer(
        id: server.id,
        label: serverLabel,
        icon: iconName.isEmpty ? nil : iconName,
        url: serverURL,
        // Password-less server discards any typed credential.
        credential: isPasswordless ? "" : credential
      )
      onDismiss()
    } catch is CancellationError {
      isCreating = false
    } catch _ as TimeoutError {
      createError = "Re-authentication failed. Timed out (10s)"
      triggerShake()
      isCreating = false
    } catch PiholeError.totpRequired {
      createError = "Your Pi-hole uses TOTP. Create an Application Password in the web UI and use it here."
      isTotpError = true
      triggerShake()
      isCreating = false
    } catch {
      createError = "Re-authentication failed: \(error.localizedDescription)"
      triggerShake()
      isCreating = false
    }
  }

  private func submit() async {
    isCreating = true
    createError = nil

    let serverURL = normalizedURL(from: url)
    let isLabelEmpty = label.trimmingCharacters(in: .whitespaces).isEmpty
    let trimmedLabel = String((isLabelEmpty ? generatedLabel : label).prefix(Self.labelMaxLength))

    if isReauthenticate {
      guard case .reauthenticate(let server) = mode else { return }
      await submitReauthentication(server: server, serverURL: serverURL)
      return
    }

    if isAdd {
      do {
        try await withThrowingTimeout(seconds: 10) {
          _ = try await serverManager.addServer(
            label: trimmedLabel,
            icon: iconName.isEmpty ? nil : iconName,
            url: serverURL,
            credential: credential
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
        icon: iconName.isEmpty ? nil : iconName,
        url: serverURL,
        // nil = keep stored credential; a typed value replaces it.
        credential: credential.isEmpty ? nil : credential
      )
      onDismiss()
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
        Text("Pi-hole v6:")
          .font(.system(size: 11, weight: .semibold))
        Text("Use your web interface password, or create an app password in Pi-hole Settings → API → App password.")
          .font(.system(size: 10))
          .foregroundColor(.secondary)

        Text("Pi-hole v5:")
          .font(.system(size: 11, weight: .semibold))
        Text("Use your API token from Pi-hole Admin Console → Settings → API → Show API token.")
          .font(.system(size: 10))
          .foregroundColor(.secondary)

        Text("No password set?")
          .font(.system(size: 11, weight: .semibold))
        Text("Leave the password field empty — password-less v5 and v6 instances are fully supported.")
          .font(.system(size: 10))
          .foregroundColor(.secondary)
      }
    }
    .padding(12)
    .frame(width: 240)
  }
}
