import SwiftUI

struct ConnectionCardView: View {
    let server: PiholeServer
    let status: ConnectionStatus
    let onEdit: () -> Void
    let onDelete: () -> Void

    enum ConnectionStatus {
        case connected
        case disconnected
        case unknown

        var color: Color {
            switch self {
            case .connected: return .green
            case .disconnected: return .red
            case .unknown: return .gray
            }
        }

        var label: String {
            switch self {
            case .connected: return "Connected"
            case .disconnected: return "Disconnected"
            case .unknown: return "Unknown"
            }
        }
    }

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
                Circle()
                    .fill(status.color)
                    .frame(width: 6, height: 6)
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
