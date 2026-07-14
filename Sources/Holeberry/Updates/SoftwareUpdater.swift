import Sparkle
import SwiftUI

// MARK: - Check for Updates View

@MainActor
final class CheckForUpdatesViewModel: ObservableObject {
  @Published var canCheckForUpdates = false

  init(updater: SPUUpdater) {
    updater.publisher(for: \.canCheckForUpdates)
      .receive(on: DispatchQueue.main)
      .assign(to: &$canCheckForUpdates)
  }
}

struct CheckForUpdatesView: View {
  @ObservedObject private var viewModel: CheckForUpdatesViewModel
  private let updater: SPUUpdater

  init(updater: SPUUpdater) {
    self.updater = updater
    self.viewModel = CheckForUpdatesViewModel(updater: updater)
  }

  var body: some View {
    Button("Check for Updates…") {
      updater.checkForUpdates()
    }
    .disabled(!viewModel.canCheckForUpdates)
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
    } header: {
      Text("Software updates")
    }
  }
}
