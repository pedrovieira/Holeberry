import Foundation
import Testing

@testable import Holeberry

// swiftlint:disable type_name empty_string

// MARK: - Browser enum

@Suite("Browser")
struct BrowserTests {
  @Test("all browsers have valid bundle IDs")
  func allHaveBundleIDs() {
    for browser in Browser.allCases {
      #expect(!browser.bundleID.isEmpty)
      #expect(!browser.appName.isEmpty)
    }
  }
}

// MARK: - ResolvedBrowserTab

@Suite("ResolvedBrowserTab")
struct ResolvedBrowserTabTests {
  @Test("Equatable")
  func equatable() {
    #expect(ResolvedBrowserTab.disabled == ResolvedBrowserTab.disabled)
    #expect(ResolvedBrowserTab.noBrowser == ResolvedBrowserTab.noBrowser)
    #expect(ResolvedBrowserTab.noURL(.safari) == ResolvedBrowserTab.noURL(.safari))
    #expect(ResolvedBrowserTab.noURL(.safari) != ResolvedBrowserTab.noURL(.chrome))
    #expect(ResolvedBrowserTab.url(.safari, "a.com") == ResolvedBrowserTab.url(.safari, "a.com"))
    #expect(ResolvedBrowserTab.url(.safari, "a.com") != ResolvedBrowserTab.url(.safari, "b.com"))
  }

  @Test("browser accessor")
  func browserAccessor() {
    #expect(ResolvedBrowserTab.disabled.browser == nil)
    #expect(ResolvedBrowserTab.noBrowser.browser == nil)
    #expect(ResolvedBrowserTab.permissionNeeded(.firefox).browser == .firefox)
    #expect(ResolvedBrowserTab.permissionDenied(.chrome).browser == .chrome)
    #expect(ResolvedBrowserTab.noURL(.safari).browser == .safari)
    #expect(ResolvedBrowserTab.url(.arc, "test.com").browser == .arc)
  }
}

// MARK: - BrowserActiveUrlFetchingStrategyFactory

@Suite("BrowserActiveUrlFetchingStrategyFactory")
struct BrowserActiveUrlFetchingStrategyFactoryTests {
  private let factory = BrowserActiveUrlFetchingStrategyFactory()

  @Test("Safari uses SafariUrlFetchingStrategy")
  func safariStrategy() {
    let strategy = factory.strategy(for: .safari)
    #expect(strategy is SafariUrlFetchingStrategy)
  }

  @Test("Chrome uses ChromiumUrlFetchingStrategy")
  func chromeStrategy() {
    let strategy = factory.strategy(for: .chrome)
    #expect(strategy is ChromiumUrlFetchingStrategy)
  }

  @Test("Firefox uses GeckoSessionStoreUrlFetchingStrategy")
  func firefoxStrategy() {
    let strategy = factory.strategy(for: .firefox)
    #expect(strategy is GeckoSessionStoreUrlFetchingStrategy)
  }

  @Test("Arc uses ChromiumUrlFetchingStrategy")
  func arcStrategy() {
    let strategy = factory.strategy(for: .arc)
    #expect(strategy is ChromiumUrlFetchingStrategy)
  }
}

// MARK: - BrowserUrlFetcher

@Suite("BrowserUrlFetcher")
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
    #expect(result == "")
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

  @Test("prefixes https:// when missing scheme")
  func prefixesHTTPSWhenMissingScheme() {
    let mockStrategy = MockBrowserActiveUrlFetchingStrategy()
    mockStrategy.stubbedURL = "example.com/path"
    let mockFactory = MockUrlStrategyFactory(mockStrategy: mockStrategy)
    let fetcher = BrowserUrlFetcher(strategyFactory: mockFactory)

    let result = fetcher.resolveCurrentTabDomain(for: .chrome)
    #expect(result == "example.com")
  }

  @Test("returns empty for internal browser pages")
  func internalPagesReturnEmpty() {
    let internalPages = [
      "about:blank",
      "chrome://settings",
      "chrome-extension://abc123",
      "edge://flags",
      "brave://bookmarks",
      "opera://history",
      "vivaldi://notes",
      "moz-extension://xyz"
    ]
    for page in internalPages {
      let mockStrategy = MockBrowserActiveUrlFetchingStrategy()
      mockStrategy.stubbedURL = page
      let mockFactory = MockUrlStrategyFactory(mockStrategy: mockStrategy)
      let fetcher = BrowserUrlFetcher(strategyFactory: mockFactory)

      let result = fetcher.resolveCurrentTabDomain(for: .chrome)
      #expect(result == "", "\(page) should return empty")
    }
  }

  @Test("returns empty for invalid URLs")
  func invalidURLReturnsEmpty() {
    let mockStrategy = MockBrowserActiveUrlFetchingStrategy()
    mockStrategy.stubbedURL = "not-a-url"
    let mockFactory = MockUrlStrategyFactory(mockStrategy: mockStrategy)
    let fetcher = BrowserUrlFetcher(strategyFactory: mockFactory)

    let result = fetcher.resolveCurrentTabDomain(for: .chrome)
    #expect(result == "")
  }
}

// MARK: - BrowserTabCoordinator

@Suite("BrowserTabCoordinator")
struct BrowserTabCoordinatorTests {
  @Test("returns .disabled when feature is off")
  func disabledWhenFeatureOff() {
    let suite = testDefaults()
    suite.set(false, forKey: "browserTabUnblockEnabled")
    let coordinator = makeCoordinator(suite: suite)

    let result = coordinator.resolve()
    #expect(result == .disabled)
  }

  @Test("returns .noBrowser when no browser detected")
  func noBrowserWhenNoneDetected() {
    let suite = testDefaults()
    suite.set(true, forKey: "browserTabUnblockEnabled")
    let monitor = MockAppFocusMonitor()
    monitor.lastSeenBrowser = nil
    let coordinator = BrowserTabCoordinator(
      monitor: monitor,
      urlFetcher: BrowserUrlFetcher(strategyFactory: MockUrlStrategyFactory()),
      defaultsSuite: suite
    )

    let result = coordinator.resolve()
    #expect(result == .noBrowser)
  }

  @Test("returns .permissionNeeded when permission not determined")
  func permissionNeeded() {
    let suite = testDefaults()
    suite.set(true, forKey: "browserTabUnblockEnabled")
    let mockStrategy = MockBrowserActiveUrlFetchingStrategy()
    mockStrategy.stubbedPermission = .notDetermined
    mockStrategy.stubbedURL = nil
    let mockFactory = MockUrlStrategyFactory(mockStrategy: mockStrategy)
    let monitor = MockAppFocusMonitor()
    monitor.lastSeenBrowser = .safari
    let coordinator = BrowserTabCoordinator(
      monitor: monitor,
      urlFetcher: BrowserUrlFetcher(strategyFactory: mockFactory),
      strategyFactory: mockFactory,
      defaultsSuite: suite
    )

    let result = coordinator.resolve()
    #expect(result == .permissionNeeded(.safari))
  }

  @Test("returns .permissionDenied when permission denied")
  func permissionDenied() {
    let suite = testDefaults()
    suite.set(true, forKey: "browserTabUnblockEnabled")
    let mockStrategy = MockBrowserActiveUrlFetchingStrategy()
    mockStrategy.stubbedPermission = .denied
    let mockFactory = MockUrlStrategyFactory(mockStrategy: mockStrategy)
    let monitor = MockAppFocusMonitor()
    monitor.lastSeenBrowser = .chrome
    let coordinator = BrowserTabCoordinator(
      monitor: monitor,
      urlFetcher: BrowserUrlFetcher(strategyFactory: mockFactory),
      strategyFactory: mockFactory,
      defaultsSuite: suite
    )

    let result = coordinator.resolve()
    #expect(result == .permissionDenied(.chrome))
  }

  @Test("returns .url with domain when available")
  func urlResolved() {
    let suite = testDefaults()
    suite.set(true, forKey: "browserTabUnblockEnabled")
    let mockStrategy = MockBrowserActiveUrlFetchingStrategy()
    mockStrategy.stubbedPermission = .allowed
    mockStrategy.stubbedURL = "https://example.com/page"
    let mockFactory = MockUrlStrategyFactory(mockStrategy: mockStrategy)
    let monitor = MockAppFocusMonitor()
    monitor.lastSeenBrowser = .safari
    let coordinator = BrowserTabCoordinator(
      monitor: monitor,
      urlFetcher: BrowserUrlFetcher(strategyFactory: mockFactory),
      strategyFactory: mockFactory,
      defaultsSuite: suite
    )

    let result = coordinator.resolve()
    #expect(result == .url(.safari, "example.com"))
  }

  /// Creates a throwaway UserDefaults suite with browserTabUnblockEnabled enabled by default.
  private func testDefaults() -> UserDefaults {
    let suite = UserDefaults(suiteName: "com.holeberry.tests.browser.\(UUID().uuidString)")!
    suite.removePersistentDomain(forName: suite.suiteName!)
    suite.set(true, forKey: "browserTabUnblockEnabled")
    return suite
  }

  private func makeCoordinator(suite: UserDefaults) -> BrowserTabCoordinator {
    BrowserTabCoordinator(
      monitor: MockAppFocusMonitor(),
      urlFetcher: BrowserUrlFetcher(strategyFactory: MockUrlStrategyFactory()),
      defaultsSuite: suite
    )
  }
}
