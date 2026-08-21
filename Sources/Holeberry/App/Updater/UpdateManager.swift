import AppKit
import OSLog
import Sparkle

final class UpdateManager: NSObject, SPUUpdaterDelegate, SPUUserDriver {
  private let logger = Logger(subsystem: Logger.appSubsystem, category: "updates")

  // Stored while the user is deciding on an update alert
  private var pendingUpdateReply: ((SPUUserUpdateChoice) -> Void)?

  lazy var updater: SPUUpdater = {
    let updater = SPUUpdater(
      hostBundle: .main,
      applicationBundle: .main,
      userDriver: self,
      delegate: self
    )
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
    logger.info("Found update: \(item.displayVersionString, privacy: .public)")

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

  // MARK: - SPUUserDriver

  func show(
    _ request: SPUUpdatePermissionRequest,
    reply: @escaping (SUUpdatePermissionResponse) -> Void
  ) {
    reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
  }

  func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {}

  func showUpdateFound(
    with appcastItem: SUAppcastItem,
    state: SPUUserUpdateState,
    reply: @escaping (SPUUserUpdateChoice) -> Void
  ) {
    // Store the reply — our delegate will call it after the user chooses
    pendingUpdateReply = reply
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
    // The user already chose "Update & Restart" in the update alert, so proceed
    // with the install without asking again.
    reply(.install)
  }

  func showInstallingUpdate(
    withApplicationTerminated applicationTerminated: Bool,
    retryTerminatingApplication: @escaping () -> Void
  ) {}

  func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
    acknowledgement()
  }

  func dismissUpdateInstallation() {}

  // MARK: - Private

  private func showUpdateAvailableAlert(for item: SUAppcastItem) {
    let alert = NSAlert()
    alert.messageText = "A new version of Holeberry is available!"

    let currentVersion = Bundle.main.releaseVersionNumber ?? "1.0"
    let newVersion = item.displayVersionString

    var info = "Holeberry \(newVersion) is now available — you have \(currentVersion)."

    // Include release notes if available
    if let notes = item.itemDescription, !notes.isEmpty {
      let plainNotes = notes.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if !plainNotes.isEmpty {
        let preview = plainNotes.count > 500 ? String(plainNotes.prefix(500)) + "\n\u{2026}" : plainNotes
        info += "\n\n\(preview)"
      }
    }

    alert.informativeText = info
    alert.alertStyle = .informational
    alert.addButton(withTitle: "Update & Restart")
    alert.addButton(withTitle: "Skip This Version")
    alert.addButton(withTitle: "Remind Me Later")

    let reply = pendingUpdateReply
    pendingUpdateReply = nil

    let response = alert.runModal()
    switch response {
    case .alertFirstButtonReturn:
      // Update & Restart — Sparkle downloads the notarized DMG and installs it
      // in place (see showReady(toInstallAndRelaunch:)).
      reply?(.install)

    case .alertSecondButtonReturn:
      // Skip This Version — Sparkle won't notify about this version again
      reply?(.skip)

    default:
      // Remind Me Later — Sparkle will re-notify on next check cycle
      reply?(.dismiss)
    }
  }
}
