import SwiftUI

struct ConnectionCardView: View {
  let config: ServerConfig
  let status: ConnectionStatus
  let onEdit: () -> Void
  let onDelete: () -> Void

  private var hostname: String {
    URLComponents(string: config.url)?.host ?? config.url
  }

  private var versionLabel: String {
    switch config.version {
    case .v5: return "v5"
    case .v6: return "v6"
    }
  }

  var body: some View {
    HStack(alignment: .center, spacing: 8) {
      PulsingStatusDot(color: status.color, isActive: status == .connected)

      VStack(alignment: .leading, spacing: 2) {
        Text(config.label ?? hostname)
          .font(.system(size: 12, weight: .semibold))
        Text(hostname)
          .font(.system(size: 10, design: .monospaced))
          .foregroundColor(.secondary)
      }

      Spacer()

      HStack(spacing: 6) {
        Text(versionLabel)
          .font(.system(size: 9, weight: .medium))
          .foregroundColor(.secondary)
          .padding(.horizontal, 6)
          .padding(.vertical, 2)
          .background(Color(nsColor: .quaternaryLabelColor))
          .clipShape(Capsule())

        Menu {
          Button("Edit...", action: onEdit)
          Button("Delete...", role: .destructive, action: onDelete)
        } label: {
          Text("···")
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(.secondary)
        }
        .menuStyle(.borderlessButton)
        .frame(width: 24, height: 24)
        .help("More options")
      }
    }
    .padding(.vertical, 4)
    .contextMenu {
      Button("Edit...", action: onEdit)
      Button("Delete...", role: .destructive, action: onDelete)
    }
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
