import Foundation

@testable import Holeberry

/// Configurable mock implementing `BrowserActiveUrlFetchingStrategy` for unit tests.
final class MockBrowserActiveUrlFetchingStrategy: BrowserActiveUrlFetchingStrategy {
  /// The URL to return from `getCurrentURL(for:)`. `nil` simulates permission denied, `""` simulates no URL.
  var stubbedURL: String?

  /// The permission to return from `isPermissionGranted(for:)`.
  var stubbedPermission: AutomationPermission = .allowed

  /// Tracks how many times `getCurrentURL(for:)` was called.
  private(set) var getCurrentURLCallCount = 0

  /// Tracks how many times `requestPermission(for:)` was called.
  private(set) var requestPermissionCallCount = 0

  func getCurrentURL(for browser: Browser) -> String? {
    getCurrentURLCallCount += 1
    return stubbedURL
  }

  func isPermissionGranted(for browser: Browser) -> AutomationPermission {
    stubbedPermission
  }

  func requestPermission(for browser: Browser) {
    requestPermissionCallCount += 1
    stubbedPermission = .allowed
  }
}
