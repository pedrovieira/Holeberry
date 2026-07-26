import Foundation

@testable import Holeberry

/// Configurable mock for `AppFocusMonitoring` that allows setting `lastSeenBrowser` directly.
@MainActor
final class MockAppFocusMonitor: AppFocusMonitoring {
  var lastSeenBrowser: Browser?
}
