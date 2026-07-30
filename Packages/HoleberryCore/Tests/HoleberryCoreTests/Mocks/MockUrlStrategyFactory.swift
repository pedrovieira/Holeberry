import Foundation

@testable import HoleberryCore

/// Configurable mock factory that returns a pre-configured mock strategy for any browser.
final class MockUrlStrategyFactory: UrlFetchingStrategyFactory {
  let mockStrategy: MockBrowserActiveUrlFetchingStrategy

  init(mockStrategy: MockBrowserActiveUrlFetchingStrategy = MockBrowserActiveUrlFetchingStrategy()) {
    self.mockStrategy = mockStrategy
  }

  func strategy(for browser: Browser) -> BrowserActiveUrlFetchingStrategy {
    mockStrategy
  }
}
