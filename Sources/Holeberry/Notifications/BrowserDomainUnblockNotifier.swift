import HoleberryCore

/// Bridges the shared core workflow to the app's notification owner.
@MainActor
final class BrowserDomainUnblockNotifier {
  private let notificationCoordinator: NotificationCoordinator

  init(notificationCoordinator: NotificationCoordinator) {
    self.notificationCoordinator = notificationCoordinator
  }

  func notify(_ result: BrowserDomainUnblockResult) async {
    guard let kind = notificationCoordinator.browserUnblockFeedback(for: result) else { return }
    await notificationCoordinator.presentBrowserUnblockFeedback(kind)
  }
}

extension NotificationCoordinator {
  func browserUnblockFeedback(for result: BrowserDomainUnblockResult) -> UserNotificationKind? {
    switch result.outcome {
    case .noServers, .inProgress, .cancelled:
      return nil
    default:
      break
    }
    // Guidance, entries already present, and per-server failures that the user needs to see.
    let notices = browserUnblockAllowedNotices(for: result) + browserUnblockMutationNotices(for: result)
    // Completed allowlist changes: entries added, temporary unblocks renewed, or entries made permanent.
    let changes = browserUnblockChanges(for: result)
    if result.outcome == .processed || result.outcome == .notBlocked {
      guard !changes.isEmpty || !notices.isEmpty else { return nil }
      return .browserDomainUnblockFeedback(body: (changes + notices).joined(separator: "\n"))
    }
    let message: String
    if case .failed(let error) = result.outcome {
      message = "Could not unblock \(result.requestedDomain): \(error.localizedDescription)"
    } else {
      message = "Could not complete the unblock for \(result.requestedDomain)."
    }
    return .browserDomainUnblockFeedback(body: ([message] + changes + notices).joined(separator: "\n"))
  }

  private func browserUnblockAllowedNotices(for result: BrowserDomainUnblockResult) -> [String] {
    result.allowedDomains.sorted().map { domain in
      """
      Pi-hole allowed recent queries for \(domain). No new allowlist entry was added for this hostname. \
      Check your browser settings or ad blocker. Other page resources may still be blocked; check Recently Blocked.
      """
    }
  }

  private func browserUnblockMutationNotices(for result: BrowserDomainUnblockResult) -> [String] {
    var notices: [String] = []
    for domain in result.mutations.keys.sorted() {
      for id in (result.mutations[domain] ?? [:]).keys.sorted(by: { $0.uuidString < $1.uuidString }) {
        let server = result.serverLabels[id] ?? "Pi-hole"
        switch result.mutations[domain]?[id] {
        case .failure(let error):
          notices.append("Failed to unblock \(domain) on \(server): \(error.localizedDescription)")
        case .success(.alreadyPresent(let enabled)):
          let content = notificationContent(
            for: .domainAlreadyAllowlisted(domain: domain, serverName: server, enabled: enabled)
          )
          notices.append("\(content.body) \(content.subtitle)")
        default:
          break
        }
      }
    }
    return notices
  }

  private func browserUnblockChanges(for result: BrowserDomainUnblockResult) -> [String] {
    var changes: [String] = []
    for domain in result.mutations.keys.sorted() {
      for id in (result.mutations[domain] ?? [:]).keys.sorted(by: { $0.uuidString < $1.uuidString }) {
        let server = result.serverLabels[id] ?? "Pi-hole"
        switch result.mutations[domain]?[id] {
        case .success(.added):
          changes.append("Unblocked \(domain) on \(server).")
        case .success(.renewed):
          changes.append("Extended the temporary unblock for \(domain) on \(server).")
        case .success(.promoted):
          changes.append("Made the unblock for \(domain) permanent on \(server).")
        default:
          break
        }
      }
    }
    return changes
  }
}
