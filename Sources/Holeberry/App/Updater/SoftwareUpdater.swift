import Sparkle
import SwiftUI

// MARK: - Check for Updates View

@MainActor
final class CheckForUpdatesViewModel: ObservableObject {
  @Published var canCheckForUpdates = false
  @Published var isCheckingForUpdates = false

  init(updater: SPUUpdater) {
    updater.publisher(for: \.canCheckForUpdates)
      .receive(on: DispatchQueue.main)
      .assign(to: &$canCheckForUpdates)

    updater.publisher(for: \.sessionInProgress)
      .receive(on: DispatchQueue.main)
      .assign(to: &$isCheckingForUpdates)
  }
}

struct CheckForUpdatesView: View {
  @ObservedObject private var viewModel: CheckForUpdatesViewModel
  private let updater: SPUUpdater
  @State private var userDidClick = false

  init(updater: SPUUpdater) {
    self.updater = updater
    self.viewModel = CheckForUpdatesViewModel(updater: updater)
  }

  var body: some View {
    Button {
      userDidClick = true
      updater.checkForUpdates()
    } label: {
      HStack(spacing: 6) {
        if viewModel.isCheckingForUpdates && userDidClick {
          ProgressView()
            .controlSize(.small)
        }
        Text(
          viewModel.isCheckingForUpdates && userDidClick
            ? "Checking…" : "Check for Updates…"
        )
      }
    }
    .disabled(!viewModel.canCheckForUpdates)
    .animation(.easeInOut(duration: 0.25), value: viewModel.isCheckingForUpdates)
    .onChange(of: viewModel.isCheckingForUpdates) { _, checking in
      if !checking { userDidClick = false }
    }
  }
}

// MARK: - Updater Settings View

struct UpdaterSettingsView: View {
  private let updater: SPUUpdater

  @State private var automaticallyChecksForUpdates: Bool

  init(updater: SPUUpdater) {
    self.updater = updater
    self.automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
  }

  var body: some View {
    Section {
      Toggle("Automatically check for updates", isOn: $automaticallyChecksForUpdates)
        .onChange(of: automaticallyChecksForUpdates) { _, newValue in
          updater.automaticallyChecksForUpdates = newValue
        }
    }
  }
}
