import SwiftUI

struct ConnectionListView: View {
    @StateObject private var manager = PiholeServerManager()
    @State private var isAdding = false
    @State private var editingServerID: UUID?
    @State private var serverStatuses: [UUID: ConnectionCardView.ConnectionStatus] = [:]
    @State private var showDeleteConfirmation = false
    @State private var serverToDelete: PiholeServer?

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("Your Pi-hole Connections")
                    .font(.system(size: 13, weight: .semibold))
                Text("Add and manage Pi-hole instances. Max 2 connections.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .padding(.bottom, 4)

            ForEach(manager.servers) { server in
                if editingServerID == server.id {
                    ConnectionFormView(
                        mode: .edit(server),
                        onSave: { label, url, password in
                            manager.updateServer(
                                id: server.id,
                                label: label,
                                url: url,
                                password: password.isEmpty ? nil : password
                            )
                            editingServerID = nil
                            return
                        },
                        onCancel: { editingServerID = nil }
                    )
                    .padding(.vertical, 4)
                } else {
                    ConnectionCardView(
                        server: server,
                        status: serverStatuses[server.id] ?? .unknown,
                        onEdit: { editingServerID = server.id },
                        onDelete: {
                            serverToDelete = server
                            showDeleteConfirmation = true
                        }
                    )
                }
            }

            if isAdding {
                ConnectionFormView(
                    mode: .add,
                    onSave: { label, url, password in
                        try await manager.addServer(label: label, url: url, password: password)
                        isAdding = false
                    },
                    onCancel: { isAdding = false }
                )
                .padding(.vertical, 4)
            }

            if manager.servers.count < 2 && !isAdding && editingServerID == nil {
                Button(action: { isAdding = true }) {
                    Label("+ New Connection", systemImage: "plus.circle")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
                .padding(.vertical, 4)
            }

            if manager.servers.count >= 2 {
                Text("Max 2 connections")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 4)
            }
        }
        .alert("Delete Connection", isPresented: $showDeleteConfirmation, presenting: serverToDelete) { server in
            Button("Cancel", role: .cancel) { serverToDelete = nil }
            Button("Delete", role: .destructive) {
                manager.deleteServer(id: server.id)
                serverToDelete = nil
            }
        } message: { server in
            Text("Delete '\(server.label ?? server.url)'? This will disconnect it from the menu bar.")
        }
        .onAppear {
            serverStatuses = [:]
            for server in manager.servers {
                serverStatuses[server.id] = .unknown
            }
        }
    }
}
