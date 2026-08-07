import Foundation
import HoleberryCore

/// Bridges core unblock-end events to `NotificationCoordinator`.
///
/// The global-unblock event arrives as a typed closure on `ServerStatusPoller`
/// (`onBlockingAutoReenabled`) — the poller is created in the composition root,
/// so it can be wired directly. The domain-unblock event arrives as a
/// `.domainUnblockExpired` NotificationCenter post, because the decorator that
/// posts it is created deep inside `PiholeServerManager`. Both become
/// notification kinds; all user-facing delivery — settings gating, copy,
/// categories — lives in `NotificationCoordinator`.
@MainActor
final class UnblockEndedNotifier {
  /// A domain unblock is applied to every server; each server's expiry task
  /// posts separately. Events for the same domain inside this window are the
  /// same unblock episode, so only the first one becomes a notification.
  private static let domainDedupeWindow: TimeInterval = 60

  private let statusMonitor: ServerStatusPoller
  private let serverManager: PiholeServerManager
  private let notificationCoordinator: NotificationCoordinator
  private let notificationCenter: NotificationCenter

  private var lastDomainNotification: (domain: String, date: Date)?

  init(
    statusMonitor: ServerStatusPoller,
    serverManager: PiholeServerManager,
    notificationCoordinator: NotificationCoordinator,
    notificationCenter: NotificationCenter = .default
  ) {
    self.statusMonitor = statusMonitor
    self.serverManager = serverManager
    self.notificationCoordinator = notificationCoordinator
    self.notificationCenter = notificationCenter

    statusMonitor.onBlockingAutoReenabled = { [weak self] serverIDs in
      self?.notifyUnblockEnded(serverIDs: serverIDs)
    }

    notificationCenter.addObserver(
      forName: .domainUnblockExpired,
      object: nil,
      queue: .main
    ) { [weak self] notification in
      guard let domain = notification.userInfo?[AppNotificationUserInfoKey.domain] as? String
      else { return }
      Task { @MainActor in
        self?.notifyDomainUnblockEnded(domain: domain)
      }
    }
  }

  private func notifyUnblockEnded(serverIDs: Set<UUID>) {
    // A single instance needs no name in the notification.
    let names =
      serverManager.servers.count > 1
      ? serverManager.servers
        .filter { serverIDs.contains($0.id) }
        .map { $0.label ?? URL(string: $0.url)?.host ?? $0.url }
      : []
    notificationCoordinator.schedule(.unblockEnded(serverNames: names))
  }

  private func notifyDomainUnblockEnded(domain: String) {
    if let last = lastDomainNotification,
      last.domain == domain,
      Date().timeIntervalSince(last.date) < Self.domainDedupeWindow
    {
      return
    }
    lastDomainNotification = (domain, Date())
    notificationCoordinator.schedule(.domainUnblockEnded(domain: domain))
  }
}
