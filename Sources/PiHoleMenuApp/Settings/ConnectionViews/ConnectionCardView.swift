import SwiftUI

struct ConnectionCardView: View {
  let server: PiholeServer
  let status: ConnectionStatus
  let onEdit: () -> Void
  let onDelete: () -> Void

  var body: some View {
    HStack(alignment: .top) {
      VStack(alignment: .leading, spacing: 2) {
        Text(server.label ?? "Instance \(server.url)")
          .font(.system(size: 12, weight: .semibold))
        Text("\(server.url) · \(server.version?.displayName ?? "Not detected")")
          .font(.system(size: 10))
          .foregroundColor(.secondary)
      }

      Spacer()

      HStack(spacing: 4) {
        PulsingStatusDot(color: status.color, isActive: status == .connected)
        Text(status.label)
          .font(.system(size: 10))
          .foregroundColor(.secondary)

        Button("Edit", action: onEdit)
          .buttonStyle(.plain)
          .font(.system(size: 10))
          .foregroundColor(.accentColor)

        Button("Delete", action: onDelete)
          .buttonStyle(.plain)
          .font(.system(size: 10))
          .foregroundColor(.red)
      }
      .fixedSize()
    }
    .padding(10)
    .background(Color(.windowBackgroundColor).opacity(0.5))
    .cornerRadius(6)
    .overlay(
      RoundedRectangle(cornerRadius: 6)
        .stroke(Color(nsColor: .separatorColor).opacity(0.3), lineWidth: 1)
    )
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
