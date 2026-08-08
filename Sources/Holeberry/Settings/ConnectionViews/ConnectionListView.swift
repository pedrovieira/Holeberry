import HoleberryCore
import SwiftUI

struct ConnectionListView: View {
  let serverManager: PiholeServerManager
  @ObservedObject var discoveryService: PiholeDiscoveryService
  @ObservedObject var statusPoller: ServerStatusPoller
  @State private var sheetMode: SheetMode?
  @State private var showDeleteConfirmation = false
  @State private var serverToDelete: ServerConfig?

  private var filteredInstances: [PiholeDiscoveryService.DiscoveredInstance] {
    discoveryService.discoveredInstances.filter { instance in
      !statusPoller.servers.contains { server in
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
      ForEach(statusPoller.servers) { server in
        ConnectionCardView(
          config: server,
          state: statusPoller.connectionStates[server.id],
          isChecking: statusPoller.checkingServerIDs.contains(server.id),
          onEdit: { sheetMode = .edit(server) },
          onDelete: {
            serverToDelete = server
            showDeleteConfirmation = true
          },
          onReauthenticate: { sheetMode = .reauthenticate(server) },
          onRetry: { await statusPoller.refreshServer(id: server.id) }
        )
        .overlay(
          RedContextMenu(
            editAction: { sheetMode = .edit(server) },
            deleteAction: {
              serverToDelete = server
              showDeleteConfirmation = true
            },
            reauthenticateAction: { sheetMode = .reauthenticate(server) },
            retryAction: {
              Task { _ = await statusPoller.refreshServer(id: server.id) }
            },
            state: statusPoller.connectionStates[server.id]
          )
        )
      }

      if statusPoller.servers.count < 2 {
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

      if statusPoller.servers.count >= 2 {
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
      if statusPoller.servers.count >= 2 {
        Text("All connection slots filled")
          .font(.system(size: 11))
          .foregroundColor(.secondary)
          .frame(height: 30)
      } else if discoveryService.isScanning && filteredInstances.isEmpty {
        Text("Scanning your network...")
          .font(.system(size: 11))
          .foregroundColor(.secondary)
          .frame(height: 30)
      } else if !discoveryService.isScanning && filteredInstances.isEmpty {
        Text("No Pi-hole instances found")
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
        if discoveryService.isScanning {
          ProgressView()
            .controlSize(.small)
        }
      }
      .textCase(nil)
    } footer: {
      Text("Scans your local network and DNS servers when you visit this tab.")
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .textCase(nil)
    }

    // --- Modals ---
    .sheet(item: $sheetMode) { mode in
      ConnectionSheet(
        mode: mode,
        serverCount: statusPoller.servers.count,
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
      statusPoller.pollNow()
      if statusPoller.servers.count < 2 {
        await discoveryService.scan()
      }
    }
    .onChange(of: statusPoller.servers.count) {
      guard statusPoller.servers.count < 2 else { return }
      Task { await discoveryService.scan() }
    }
    .onChange(of: sheetMode) { _, newMode in
      if newMode == nil {
        Task { statusPoller.pollNow() }
      }
    }
  }
}

// MARK: - Discovered Row

private struct DiscoveredRow: View {
  let instance: PiholeDiscoveryService.DiscoveredInstance
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
