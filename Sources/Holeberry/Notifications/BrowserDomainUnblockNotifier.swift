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
    let notices = browserUnblockNotices(for: result)
    if result.outcome == .processed {
      guard !notices.isEmpty else { return nil }
      let changes = browserUnblockChanges(for: result)
      return .browserDomainUnblockFeedback(body: (changes + notices).joined(separator: "\n"))
    }
    let domains = (result.candidateDomains.isEmpty ? [result.requestedDomain] : result.candidateDomains)
      .joined(separator: " or ")
    let scope = "from this Mac's detected IPv4 address (\(result.clientIP ?? "unavailable"))"
    let message: String
    switch result.outcome {
    case .noHistory:
      message = """
        No query for \(domains) \(scope) was found in the last 15 minutes. \
        Check your browser's ad blocker or connection. No new unblock was applied.
        """
    case .notBlocked:
      message = """
        No Pi-hole rule block was found for \(domains) \(scope) in the last 15 minutes. \
        Check your browser's ad blocker or connection. No new unblock was applied.
        """
    case .upstreamBlocked:
      message = """
        Recent queries for \(domains) \(scope) were blocked by upstream DNS. \
        A Pi-hole allowlist entry may not help. No new unblock was applied.
        """
    case .missingClientIP:
      message = """
        Could not detect this Mac's IPv4 address to check recent queries for \(domains). \
        No new unblock was applied.
        """
    case .failed(let error):
      message = "Could not unblock \(domains): \(error.localizedDescription) No new unblock was applied."
    default:
      message = """
        Could not complete the recent-query check for \(domains) \(scope). No new unblock was applied.
        """
    }
    return .browserDomainUnblockFeedback(body: ([message] + notices).joined(separator: "\n"))
  }

  private func browserUnblockNotices(for result: BrowserDomainUnblockResult) -> [String] {
    var notices: [String] = []
    for domain in result.checks.keys.sorted() {
      for id in (result.checks[domain] ?? [:]).keys.sorted(by: { $0.uuidString < $1.uuidString }) {
        let server = result.serverLabels[id] ?? "Pi-hole"
        switch result.checks[domain]?[id] {
        case .failure(let error):
          notices.append("Could not check recent queries for \(domain) on \(server): \(error.localizedDescription)")
        case .success(.unavailable):
          notices.append("Recent query results for \(domain) on \(server) were incomplete or inconclusive.")
        default:
          break
        }
      }
    }
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
