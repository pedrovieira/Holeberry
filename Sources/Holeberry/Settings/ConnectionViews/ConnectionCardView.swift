import HoleberryCore
import SwiftUI

struct ConnectionCardView: View {
  let config: ServerConfig
  let state: ServerConnectionState?
  let isChecking: Bool
  let onEdit: () -> Void
  let onDelete: () -> Void
  let onReauthenticate: () -> Void
  let onRetry: () async -> ServerConnectionState

  @State private var manualRetryFailed = false

  private var hostname: String {
    URLComponents(string: config.url)?.host ?? config.url
  }

  private var versionLabel: String {
    switch config.version {
    case .v5: return "v5"
    case .v6: return "v6"
    }
  }

  private var dotColor: Color {
    switch state {
    case .healthy: return .green
    case .authError: return .red
    case .unreachable, nil: return .gray
    }
  }

  private var isErrorState: Bool {
    if case .authError = state { return true }
    if case .unreachable = state { return true }
    return false
  }

  var body: some View {
    HStack(alignment: .center, spacing: 8) {
      PulsingStatusDot(color: dotColor, isActive: state == .healthy)
        // Pin the layout slot so the row content doesn't shift 2pt when
        // the pulse (8x8) appears next to the dot (6x6).
        .frame(width: 6, height: 6)

      if let icon = config.icon {
        Image(systemName: icon)
          .font(.system(size: 12))
          .foregroundColor(.secondary)
      }

      VStack(alignment: .leading, spacing: 2) {
        Text(config.label ?? hostname)
          .font(.system(size: 12, weight: .semibold))
          .lineLimit(1)
          .truncationMode(.tail)
        subtitleView
      }
      // Beat the Spacer when the row is a few points short of its ideal
      // width: otherwise the subtitle wraps ("Password may / have changed")
      // while the Spacer keeps dead space. The fix button's own priority
      // still protects it inside the trailing button HStack.
      .layoutPriority(1)

      Spacer()

      HStack(spacing: 6) {
        if isErrorState {
          fixButton
        } else {
          Text(versionLabel)
            .font(.system(size: 9, weight: .medium))
            .foregroundColor(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color(nsColor: .quaternaryLabelColor))
            .clipShape(Capsule())
        }

        RedMenuButton(
          editAction: onEdit,
          deleteAction: onDelete,
          reauthenticateAction: onReauthenticate,
          retryAction: { Task { _ = await onRetry() } },
          state: state
        )
        .frame(width: 22, height: 22)
        .fixedSize()
      }
    }
    .padding(.vertical, 4)
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
    .onChange(of: state) { _, _ in
      manualRetryFailed = false
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityLabelText)
    .accessibilityAction {
      // The combined element announces the fix button; make it activatable.
      performFixAction()
    }
  }

  /// The action behind the fix button — shared by the button and the
  /// combined accessibility element.
  private func performFixAction() {
    if case .unreachable = state, manualRetryFailed {
      onEdit()
    } else if case .unreachable = state {
      Task {
        let result = await onRetry()
        if result != .healthy {
          manualRetryFailed = true
        }
      }
    } else {
      onReauthenticate()
    }
  }

  @ViewBuilder
  private var subtitleView: some View {
    switch state {
    case .authError(let reason):
      HStack(spacing: 4) {
        Image(systemName: "lock.fill")
          .font(.system(size: 13))
          .foregroundColor(.red.opacity(0.85))
        Text(reason.subtitleText)
          .font(.system(size: 12))
          .foregroundColor(.red.opacity(0.85))
          .lineLimit(2)
          .offset(y: 1)
      }
    case .unreachable(let lastSeen):
      HStack(spacing: 4) {
        Image(systemName: "wifi.slash")
          .font(.system(size: 13))
          .foregroundColor(.secondary)
        Text(unreachableSubtitle(lastSeen: lastSeen))
          .font(.system(size: 12))
          .foregroundColor(.secondary)
          .lineLimit(2)
      }
    default:
      Button {
        if let url = URL(string: config.url + "/admin") {
          NSWorkspace.shared.open(url)
        }
      } label: {
        HStack(spacing: 3) {
          Text(hostname)
            .font(.system(size: 10, design: .monospaced))
            .foregroundColor(.secondary)
          Image(systemName: "arrow.up.forward.square")
            .font(.system(size: 10))
            .foregroundColor(.secondary)
        }
      }
      .buttonStyle(PlainButtonStyle())
      .help("Open in browser")
    }
  }

  private var fixButton: some View {
    let title: String
    let action: () -> Void
    if case .unreachable = state, manualRetryFailed {
      title = String(localized: "Fix")
      action = onEdit
    } else if case .unreachable = state {
      title = String(localized: "Retry")
      action = { performFixAction() }
    } else {
      title = String(localized: "Re-authenticate")
      action = onReauthenticate
    }

    return Button(action: action) {
      Group {
        if isChecking {
          ProgressView()
            .controlSize(.small)
        } else {
          Text(title)
        }
      }
      .font(.system(size: 12, weight: .medium))
    }
    .buttonStyle(.bordered)
    .controlSize(.small)
    // The action label must never truncate or wrap — the button keeps its
    // full width; the title truncates and the issue text wraps instead.
    // Width is content-driven ("Retry" hugs, "Re-authenticate" is wider);
    // the spinner is narrower than every label, so the swap never reflows.
    .layoutPriority(2)
    .accessibilityLabel(accessibilityFixButtonLabel(title: title))
  }

  private func unreachableSubtitle(lastSeen: Date?) -> String {
    guard let lastSeen else {
      return String(localized: "Unreachable")
    }
    // Minute granularity only — round down and floor at 1 minute so the
    // subtitle doesn't churn on every poll ("5 sec. ago" → "35 sec. ago").
    let minutes = max(1, Int(Date().timeIntervalSince(lastSeen) / 60))
    let relative = RelativeDateTimeFormatter()
    relative.unitsStyle = .short
    // Feed a date exactly `minutes` in the past so the formatter always
    // lands on whole minutes ("5 min. ago", never "4 min. 30 sec. ago").
    let relativeTime = relative.localizedString(
      for: Date().addingTimeInterval(-TimeInterval(minutes) * 60),
      relativeTo: Date()
    )
    return String(localized: "Unreachable · \(relativeTime)")
  }

  private var accessibilityLabelText: String {
    let name = config.label ?? hostname
    switch state {
    case .authError(let reason):
      return "\(name), \(reason.subtitleText), button: Re-authenticate"
    case .unreachable:
      return "\(name), unreachable, button: \(manualRetryFailed ? "Edit connection" : "Retry")"
    case .healthy, nil:
      return name
    }
  }

  private func accessibilityFixButtonLabel(title: String) -> String {
    "\(title) \(config.label ?? hostname)"
  }
}

struct PulsingStatusDot: View {
  let color: Color
  let isActive: Bool

  @State private var isPulsing = false

  var body: some View {
    ZStack {
      if isActive {
        Circle()
          .fill(color.opacity(0.35))
          .frame(width: 8, height: 8)
          .scaleEffect(isPulsing ? 2.5 : 1.0)
          .opacity(isPulsing ? 0.0 : 0.6)
      }

      Circle()
        .fill(color)
        .frame(width: 6, height: 6)
    }
    .onAppear { startPulse() }
    .onChange(of: isActive) { _, nowActive in
      if nowActive {
        startPulse()
      } else {
        isPulsing = false
      }
    }
  }

  private func startPulse() {
    guard isActive else { return }
    withAnimation(
      .easeOut(duration: 1.5)
        .repeatForever(autoreverses: false)
    ) {
      isPulsing = true
    }
  }
}
