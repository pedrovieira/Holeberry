import Foundation

@testable import HoleberryCore

/// Configurable mock for `AppFocusMonitoring` that allows setting `lastSeenBrowser` directly.
@MainActor
final class MockAppFocusMonitor: AppFocusMonitoring {
  var lastSeenBrowser: Browser?
}
