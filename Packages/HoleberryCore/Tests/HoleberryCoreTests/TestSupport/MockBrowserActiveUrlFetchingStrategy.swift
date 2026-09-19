import Foundation

@testable import HoleberryCore

/// Configurable mock implementing `BrowserActiveUrlFetchingStrategy` for unit tests.
final class MockBrowserActiveUrlFetchingStrategy: BrowserActiveUrlFetchingStrategy {
  /// The browser this mock was built for.
  let browser: Browser

  /// The URL string to return from `getCurrentURL()`; parsed into a URL by the
  /// mock. `nil` or an unparseable string simulates no URL available.
  var stubbedURL: String?

  /// The access state to return from `accessState()` once the queue below is empty.
  var stubbedAccessState: BrowserAccessState = .allowed

  /// Per-call overrides for `accessState()`; each call pops the next value.
  var stubbedAccessStateQueue: [BrowserAccessState] = []

  /// Tracks how many times `getCurrentURL()` was called.
  private(set) var getCurrentURLCallCount = 0

  /// Tracks how many times `accessState()` was called.
  private(set) var accessStateCallCount = 0

  /// Tracks how many times `requestAccess()` was called.
  private(set) var requestAccessCallCount = 0

  init(browser: Browser = .safari) {
    self.browser = browser
  }

  func getCurrentURL() -> URL? {
    getCurrentURLCallCount += 1
    return stubbedURL.flatMap { URL(string: $0) }
  }

  func accessState() -> BrowserAccessState {
    accessStateCallCount += 1
    if !stubbedAccessStateQueue.isEmpty {
      return stubbedAccessStateQueue.removeFirst()
    }
    return stubbedAccessState
  }

  func requestAccess() {
    requestAccessCallCount += 1
    // Leaves the queue untouched: a real dialog's outcome would surface on
    // the next `accessState` probe, which is what the queue models.
  }
}
