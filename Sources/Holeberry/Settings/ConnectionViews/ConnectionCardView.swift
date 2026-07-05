import SwiftUI

struct ConnectionCardView: View {
  let config: ServerConfig
  let status: ConnectionStatus
  let onEdit: () -> Void
  let onDelete: () -> Void

  @State private var showPopover = false

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

        Button {
          showPopover = true
        } label: {
          Text("···")
            .font(.system(size: 11, weight: .medium))
            .frame(width: 22, height: 22)
        }
        .buttonStyle(.borderless)
        .background(
          RoundedRectangle(cornerRadius: 5)
            .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
          RoundedRectangle(cornerRadius: 5)
            .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        )
        .popover(isPresented: $showPopover, arrowEdge: .trailing) {
          VStack(alignment: .leading, spacing: 0) {
            Button("Edit...") {
              showPopover = false
              onEdit()
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            Button("Delete...") {
              showPopover = false
              onDelete()
            }
            .buttonStyle(.plain)
            .foregroundColor(.red)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
          }
          .padding(.vertical, 4)
          .frame(minWidth: 120)
        }
        .help("More options")
      }
    }
    .padding(.vertical, 4)
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
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
