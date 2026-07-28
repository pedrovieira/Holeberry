import Foundation
import Testing

@testable import Holeberry

@Suite("BrowserUrlFetcher")
@MainActor
struct BrowserUrlFetcherTests {
  @Test("returns nil when strategy returns nil (permission denied)")
  func nilResultDenied() {
    let mockStrategy = MockBrowserActiveUrlFetchingStrategy()
    mockStrategy.stubbedURL = nil
    let mockFactory = MockUrlStrategyFactory(mockStrategy: mockStrategy)
    let fetcher = BrowserUrlFetcher(strategyFactory: mockFactory)
    let result = fetcher.resolveCurrentTabDomain(for: .safari)
    #expect(result == nil)
  }

  @Test("returns empty string when strategy returns empty (no URL)")
  func emptyResultNoURL() {
    let mockStrategy = MockBrowserActiveUrlFetchingStrategy()
    mockStrategy.stubbedURL = ""
    let mockFactory = MockUrlStrategyFactory(mockStrategy: mockStrategy)
    let fetcher = BrowserUrlFetcher(strategyFactory: mockFactory)
    let result = fetcher.resolveCurrentTabDomain(for: .safari)
    #expect(result?.isEmpty == true)
  }

  @Test("extracts host from http URL")
  func extractsHostFromHTTP() {
    let mockStrategy = MockBrowserActiveUrlFetchingStrategy()
    mockStrategy.stubbedURL = "http://www.example.com/page"
    let mockFactory = MockUrlStrategyFactory(mockStrategy: mockStrategy)
    let fetcher = BrowserUrlFetcher(strategyFactory: mockFactory)
    let result = fetcher.resolveCurrentTabDomain(for: .chrome)
    #expect(result == "www.example.com")
  }

  @Test("extracts host from https URL")
  func extractsHostFromHTTPS() {
    let mockStrategy = MockBrowserActiveUrlFetchingStrategy()
    mockStrategy.stubbedURL = "https://google.com/search?q=test"
    let mockFactory = MockUrlStrategyFactory(mockStrategy: mockStrategy)
    let fetcher = BrowserUrlFetcher(strategyFactory: mockFactory)
    let result = fetcher.resolveCurrentTabDomain(for: .chrome)
    #expect(result == "google.com")
  }

  @Test("returns empty for URL without scheme")
  func urlWithoutSchemeReturnsEmpty() {
    let mockStrategy = MockBrowserActiveUrlFetchingStrategy()
    mockStrategy.stubbedURL = "example.com/path"
    let mockFactory = MockUrlStrategyFactory(mockStrategy: mockStrategy)
    let fetcher = BrowserUrlFetcher(strategyFactory: mockFactory)
    let result = fetcher.resolveCurrentTabDomain(for: .chrome)
    #expect(result?.isEmpty == true)
  }

  @Test("returns empty for internal browser pages")
  func internalPagesReturnEmpty() {
    for page in [
      "about:blank", "chrome://settings", "chrome-extension://abc123",
      "edge://flags", "brave://bookmarks", "opera://history",
      "vivaldi://notes", "moz-extension://xyz"
    ] {
      let mockStrategy = MockBrowserActiveUrlFetchingStrategy()
      mockStrategy.stubbedURL = page
      let mockFactory = MockUrlStrategyFactory(mockStrategy: mockStrategy)
      let fetcher = BrowserUrlFetcher(strategyFactory: mockFactory)
      let result = fetcher.resolveCurrentTabDomain(for: .chrome)
      #expect(result?.isEmpty == true, "\(page) should return empty")
    }
  }

  @Test("returns empty for non-http URLs")
  func nonHTTPURLReturnsEmpty() {
    let mockStrategy = MockBrowserActiveUrlFetchingStrategy()
    mockStrategy.stubbedURL = "not-a-url"
    let mockFactory = MockUrlStrategyFactory(mockStrategy: mockStrategy)
    let fetcher = BrowserUrlFetcher(strategyFactory: mockFactory)
    let result = fetcher.resolveCurrentTabDomain(for: .chrome)
    #expect(result?.isEmpty == true)
  }
}
