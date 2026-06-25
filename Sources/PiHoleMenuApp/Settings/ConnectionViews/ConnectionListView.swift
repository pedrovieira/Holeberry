import SwiftUI

struct ConnectionListView: View {
  @ObservedObject private var monitor = ServerStatusMonitor.shared
  @State private var sheetMode: SheetMode?
  @State private var showDeleteConfirmation = false
  @State private var serverToDelete: ServerConfig?

  // Scanner state
  @State private var discoveredInstances: [PiHoleScanner.DiscoveredInstance] = []
  @State private var isScanning = false

  private var connectedCount: Int {
    monitor.connectionStatuses.values.filter { $0 == .connected }.count
  }

  private var filteredInstances: [PiHoleScanner.DiscoveredInstance] {
    discoveredInstances.filter { instance in
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
      }

      if monitor.servers.count < 2 {
        Button {
          sheetMode = .add(prefillURL: nil)
        } label: {
          Label("New Connection", systemImage: "plus.circle")
            .font(.system(size: 12))
        }
        .buttonStyle(.plain)
        .foregroundColor(.accentColor)
        .padding(.vertical, 4)
      }

      if monitor.servers.count >= 2 {
        Text("Max 2 connections")
          .font(.system(size: 11))
          .foregroundColor(.secondary)
          .frame(maxWidth: .infinity)
          .padding(.top, 4)
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
      if isScanning && filteredInstances.isEmpty {
        HStack {
          Text("Scanning your network...")
            .font(.system(size: 11))
            .foregroundColor(.secondary)
          Spacer()
          ProgressView()
            .controlSize(.small)
        }
      } else if !isScanning && filteredInstances.isEmpty && connectedCount < 2 {
        Text("No Pi-hole instances found on your network")
          .font(.system(size: 11))
          .foregroundColor(.secondary)
      }

      if connectedCount >= 2 {
        Text("All connection slots filled")
          .font(.system(size: 11))
          .foregroundColor(.secondary)
      } else {
        ForEach(filteredInstances) { instance in
          DiscoveredRow(instance: instance) {
            sheetMode = .add(prefillURL: "http://\(instance.addr)")
          }
        }
      }
    } header: {
      HStack {
        Text("Instances Found")
          .font(.headline)
        Spacer()
        if isScanning {
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
        onSave: { label, url, password, _ in
          switch mode {
          case .add:
            try await monitor.addServer(label: label, url: url, credential: password)
          case .edit:
            if case .edit(let server) = mode {
              await monitor.updateServer(
                id: server.id,
                label: label,
                url: url,
                credential: password.isEmpty ? nil : password
              )
            }
          }
          sheetMode = nil
        },
        onCancel: { sheetMode = nil },
        serverManager: .shared
      )
    }
    .alert("Delete Connection", isPresented: $showDeleteConfirmation, presenting: serverToDelete) { server in
      Button("Cancel", role: .cancel) { serverToDelete = nil }
      Button("Delete", role: .destructive) {
        monitor.deleteServer(id: server.id)
        serverToDelete = nil
      }
    } message: { server in
      Text("Delete '\(server.label ?? server.url)'? This will disconnect it from the menu bar.")
    }

    // --- Lifecycle ---
    .task {
      await monitor.pollNow()
      await runScanIfNeeded()
    }
    .onChange(of: monitor.servers.count) { _ in
      Task { await runScanIfNeeded() }
    }
  }

  // MARK: - Scanning

  private func runScanIfNeeded() async {
    guard connectedCount < 2 else {
      discoveredInstances = []
      isScanning = false
      return
    }

    isScanning = true
    discoveredInstances = await PiHoleScanner.scan()
    isScanning = false
  }
}

// MARK: - Discovered Row

private struct DiscoveredRow: View {
  let instance: PiHoleScanner.DiscoveredInstance
  let onAdd: () -> Void

  @State private var isHovering = false

  var body: some View {
    HStack {
      Image(systemName: "shield.lefthalf.filled")
        .foregroundStyle(.green)
        .font(.system(size: 14))

      Text(instance.addr)
        .font(.system(size: 12, design: .monospaced))

      Spacer()

      if isHovering {
        Button("Add") { onAdd() }
          .buttonStyle(.plain)
          .foregroundColor(.accentColor)
          .font(.system(size: 11))
      }

      Button {
        NSWorkspace.shared.open(instance.adminURL)
      } label: {
        Image(systemName: "arrow.up.forward.square")
          .font(.system(size: 12))
      }
      .buttonStyle(.plain)
      .foregroundColor(.secondary)
    }
    .padding(.vertical, 2)
    .onHover { hovering in
      withAnimation(.easeInOut(duration: 0.15)) {
        isHovering = hovering
      }
    }
  }
}
