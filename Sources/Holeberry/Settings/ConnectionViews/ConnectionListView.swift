import SwiftUI

struct ConnectionListView: View {
  let serverManager: PiholeServerManager
  @ObservedObject private var monitor = ServerStatusMonitor.shared
  @State private var sheetMode: SheetMode?
  @State private var showDeleteConfirmation = false
  @State private var serverToDelete: ServerConfig?

  private var connectedCount: Int {
    monitor.connectionStatuses.values.filter { $0 == .connected }.count
  }

  private var filteredInstances: [PiholeScanner.DiscoveredInstance] {
    monitor.discoveredInstances.filter { instance in
      !monitor.servers.contains { server in
        guard let components = URLComponents(string: server.url),
          let host = components.host
        else {
          return server.url.contains(instance.addr)
        }
        return host == instance.addr
      }
    }
  }

  var body: some View {
    // --- Section 1: Existing connections ---
    Section {
      ForEach(monitor.servers) { server in
        ConnectionCardView(
          config: server,
          status: monitor.connectionStatuses[server.id] ?? .unknown,
          onEdit: { sheetMode = .edit(server) },
          onDelete: {
            serverToDelete = server
            showDeleteConfirmation = true
          }
        )
        .overlay(
          RedContextMenu(
            editAction: { sheetMode = .edit(server) },
            deleteAction: {
              serverToDelete = server
              showDeleteConfirmation = true
            }
          )
        )
      }

      if monitor.servers.count < 2 {
        Button {
          sheetMode = .add(prefillURL: nil)
        } label: {
          Label("New Connection", systemImage: "plus.circle")
            .font(.system(size: 12))
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundColor(.accentColor)
        .padding(.vertical, 4)
      }

      if monitor.servers.count >= 2 {
        HStack(spacing: 6) {
          Image(systemName: "plus")
          Text("Maximum connections reached")
        }
        .font(.system(size: 11))
        .foregroundColor(.secondary)
        .opacity(0.4)
        .allowsHitTesting(false)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
      }
    } header: {
      VStack(alignment: .leading, spacing: 4) {
        Text("Your Pi-hole connections")
          .font(.headline)
        Text("Add and manage Pi-hole instances. Max 2 connections.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
      .textCase(nil)
      .padding(.bottom, 4)
    }

    // --- Section 2: Instances Found ---
    Section {
      if monitor.isScanning && filteredInstances.isEmpty {
        Text("Scanning your network...")
          .font(.system(size: 11))
          .foregroundColor(.secondary)
          .frame(height: 30)
      } else if !monitor.isScanning && filteredInstances.isEmpty && connectedCount < 2 {
        Text("No Pi-hole instances found on your network")
          .font(.system(size: 11))
          .foregroundColor(.secondary)
          .frame(height: 30)
      }

      if connectedCount >= 2 {
        Text("All connection slots filled")
          .font(.system(size: 11))
          .foregroundColor(.secondary)
          .frame(height: 30)
      } else {
        ForEach(filteredInstances) { instance in
          DiscoveredRow(instance: instance) {
            sheetMode = .add(prefillURL: "http://\(instance.addr)")
          }
        }
      }
    } header: {
      HStack {
        Text("Available Instances")
          .font(.headline)
        Spacer()
        if monitor.isScanning {
          ProgressView()
            .controlSize(.small)
        }
      }
      .textCase(nil)
    } footer: {
      Text("Scans your local network when you visit this tab.")
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .textCase(nil)
    }

    // --- Modals ---
    .sheet(item: $sheetMode) { mode in
      ConnectionSheet(
        mode: mode,
        serverCount: monitor.servers.count,
        onDismiss: { sheetMode = nil },
        onCancel: { sheetMode = nil },
        serverManager: serverManager
      )
    }
    .alert("Delete Connection", isPresented: $showDeleteConfirmation, presenting: serverToDelete) { server in
      Button("Cancel", role: .cancel) { serverToDelete = nil }
      Button("Delete", role: .destructive) {
        serverManager.deleteServer(id: server.id)
        serverToDelete = nil
      }
    } message: { server in
      Text("Delete '\(server.label ?? server.url)'? This will disconnect it from the menu bar.")
    }

    // --- Lifecycle ---
    .task {
      monitor.pollNow()
      await monitor.runScanIfNeeded()
    }
    .onChange(of: monitor.servers.count) {
      Task { await monitor.runScanIfNeeded() }
    }
  }
}

// MARK: - Discovered Row

private struct DiscoveredRow: View {
  let instance: PiholeScanner.DiscoveredInstance
  let onAdd: () -> Void

  @State private var isHovering = false

  var body: some View {
    HStack {
      Image(systemName: "shield.lefthalf.filled")
        .foregroundStyle(.green)
        .font(.system(size: 14))
      Button {
        NSWorkspace.shared.open(instance.adminURL)
      } label: {
        HStack(spacing: 3) {
          Text(instance.addr)
            .font(.system(size: 12, design: .monospaced))
          Image(systemName: "arrow.up.forward.square")
            .font(.system(size: 11))
            .foregroundColor(.secondary)
            .padding(.leading, 2)
        }
      }
      .buttonStyle(.plain)
      .help("Open in your default browser")
      Spacer()
      Button("Add") { onAdd() }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .frame(height: 24)
        .opacity(isHovering ? 1 : 0)
        .disabled(!isHovering)
    }
    .padding(.horizontal, 2)
    .frame(height: 30)
    .contentShape(Rectangle())
    .onHover { isHovering = $0 }
    .listRowInsets(EdgeInsets())
  }
}
