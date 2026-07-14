import AppKit
import OSLog
import Sparkle

final class UpdateManager: NSObject, SPUUpdaterDelegate {
  private let userDriver = HoleberryUserDriver()
  private let logger = Logger(subsystem: Logger.appSubsystem, category: "updates")

  lazy var updater: SPUUpdater = {
    let updater = SPUUpdater(
      hostBundle: .main,
      applicationBundle: .main,
      userDriver: userDriver,
      delegate: self
    )
    // Don't auto-download since we're not signed
    updater.automaticallyDownloadsUpdates = false
    updater.automaticallyChecksForUpdates = true
    do {
      try updater.start()
    } catch {
      logger.error("Failed to start updater: \(error.localizedDescription, privacy: .public)")
    }
    return updater
  }()

  // MARK: - SPUUpdaterDelegate

  func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
    logger.info("Found update: \(item.displayVersionString ?? "unknown", privacy: .public)")

    DispatchQueue.main.async { [weak self] in
      self?.showUpdateAvailableAlert(for: item)
    }
  }

  func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
    logger.info("No updates available")
  }

  func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
    logger.error("Updater error: \(error.localizedDescription, privacy: .public)")
  }

  // MARK: - Private

  private func showUpdateAvailableAlert(for item: SUAppcastItem) {
    let alert = NSAlert()
    alert.messageText = "A new version of Holeberry is available!"
    let version = Bundle.main.releaseVersionNumber ?? "1.0"
    alert.informativeText = "Holeberry \(item.displayVersionString ?? "") is now available — you have \(version)."
    alert.alertStyle = .informational
    alert.addButton(withTitle: "View on GitHub")
    alert.addButton(withTitle: "Remind Me Later")

    let response = alert.runModal()
    if response == .alertFirstButtonReturn {
      if let url = URL(string: "https://github.com/pedrovieira/Holeberry/releases") {
        NSWorkspace.shared.open(url)
      }
    }
  }
}

// MARK: - Minimal User Driver

/// Minimal SPUUserDriver that suppresses Sparkle's standard UI.
/// Update-found events are handled by `UpdateManager`'s delegate instead.
private final class HoleberryUserDriver: NSObject, SPUUserDriver {
  func show(
    _ request: SPUUpdatePermissionRequest,
    reply: @escaping (SUUpdatePermissionResponse) -> Void
  ) {
    reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
  }

  func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
    // No UI to show
  }

  func showUpdateFound(
    with appcastItem: SUAppcastItem,
    state: SPUUserUpdateState,
    reply: @escaping (SPUUserUpdateChoice) -> Void
  ) {
    // Suppress Sparkle's standard alert — our delegate handles it
    reply(.dismiss)
  }

  func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}

  func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}

  func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
    acknowledgement()
  }

  func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
    acknowledgement()
  }

  func showDownloadInitiated(cancellation: @escaping () -> Void) {}

  func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {}

  func showDownloadDidReceiveData(ofLength length: UInt64) {}

  func showDownloadDidStartExtractingUpdate() {}

  func showExtractionReceivedProgress(_ progress: Double) {}

  func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
    reply(.dismiss)
  }

  func showInstallingUpdate(
    withApplicationTerminated applicationTerminated: Bool,
    retryTerminatingApplication: @escaping () -> Void
  ) {}

  func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
    acknowledgement()
  }

  func dismissUpdateInstallation() {}
}

// MARK: - Bundle Version Helpers

extension Bundle {
  var releaseVersionNumber: String? {
    infoDictionary?["CFBundleShortVersionString"] as? String
  }

  var buildVersionNumber: String? {
    infoDictionary?["CFBundleVersion"] as? String
  }
}
