import Defaults
import Foundation
import Testing

@testable import HoleberryCore

@Suite("BrowserTabCoordinator")
@MainActor
struct BrowserTabCoordinatorTests {
  @Test("returns .disabled when feature is off")
  func disabledWhenFeatureOff() {
    let suite = testDefaults()
    Defaults[.browserTabUnblockEnabled(suite: suite)] = false
    let coordinator = makeCoordinator(suite: suite)
    let result = coordinator.resolve()
    #expect(result == .disabled)
  }

  @Test("returns .noBrowser when no browser detected")
  func noBrowserWhenNoneDetected() {
    let suite = testDefaults()
    let monitor = MockAppFocusMonitor()
    monitor.lastSeenBrowser = nil
    let coordinator = BrowserTabCoordinator(
      monitor: monitor,
      urlFetcher: BrowserUrlFetcher(strategyFactory: MockUrlStrategyFactory()),
      strategyFactory: MockUrlStrategyFactory(),
      defaultsSuite: suite
    )
    let result = coordinator.resolve()
    #expect(result == .noBrowser)
  }

  @Test("returns .permissionNeeded when permission not determined")
  func permissionNeeded() {
    let suite = testDefaults()
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

  // MARK: - lastSeenBrowser

  @Test("lastSeenBrowser returns nil when no browser is focused")
  func lastSeenBrowserNil() {
    let suite = testDefaults()
    let coordinator = makeCoordinator(suite: suite)
    #expect(coordinator.lastSeenBrowser == nil, "Should return nil when no browser is focused")
  }

  @Test("lastSeenBrowser returns the last-seen browser from the monitor")
  func lastSeenBrowserValue() {
    let suite = testDefaults()
    let monitor = MockAppFocusMonitor()
    monitor.lastSeenBrowser = .safari
    let coordinator = makeCoordinator(monitor: monitor, suite: suite)
    #expect(coordinator.lastSeenBrowser == .safari, "Should return .safari when that browser is focused")
  }

  // MARK: - requestPermissionAndResolve

  @Test("requestPermissionIfNeededAndResolve returns .disabled when feature is off")
  func requestPermissionDisabledWhenFeatureOff() {
    let suite = testDefaults()
    Defaults[.browserTabUnblockEnabled(suite: suite)] = false
    let coordinator = makeCoordinator(suite: suite)
    let result = coordinator.requestPermissionIfNeededAndResolve()
    #expect(result == .disabled, "Should return .disabled when browser tab unblock is disabled")
  }

  @Test("requestPermissionIfNeededAndResolve returns .noBrowser when no browser detected")
  func requestPermissionNoBrowser() {
    let suite = testDefaults()
    let monitor = MockAppFocusMonitor()
    monitor.lastSeenBrowser = nil
    let coordinator = makeCoordinator(monitor: monitor, suite: suite)
    let result = coordinator.requestPermissionIfNeededAndResolve()
    #expect(result == .noBrowser, "Should return .noBrowser when no browser is focused")
  }

  @Test("requestPermissionIfNeededAndResolve requests permission and resolves URL when permission not determined")
  func requestPermissionResolvesAfterRequest() {
    let suite = testDefaults()
    let mockStrategy = MockBrowserActiveUrlFetchingStrategy()
    mockStrategy.stubbedPermission = .notDetermined
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
    let result = coordinator.requestPermissionIfNeededAndResolve()
    #expect(mockStrategy.requestPermissionCallCount == 1, "Should have called requestPermission once")
    #expect(result == .url(.safari, "example.com"), "Should resolve to URL after permission is granted")
  }

  @Test("requestPermissionIfNeededAndResolve requests permission when denied and resolves URL")
  func requestPermissionResolvesAfterDenied() {
    let suite = testDefaults()
    let mockStrategy = MockBrowserActiveUrlFetchingStrategy()
    mockStrategy.stubbedPermission = .denied
    mockStrategy.stubbedURL = "https://example.com/page"
    let mockFactory = MockUrlStrategyFactory(mockStrategy: mockStrategy)
    let monitor = MockAppFocusMonitor()
    monitor.lastSeenBrowser = .chrome
    let coordinator = BrowserTabCoordinator(
      monitor: monitor,
      urlFetcher: BrowserUrlFetcher(strategyFactory: mockFactory),
      strategyFactory: mockFactory,
      defaultsSuite: suite
    )
    let result = coordinator.requestPermissionIfNeededAndResolve()
    #expect(mockStrategy.requestPermissionCallCount == 1, "Should have called requestPermission once")
    #expect(result == .url(.chrome, "example.com"), "Should resolve to URL after permission request")
  }

  @Test("requestPermissionIfNeededAndResolve returns .noURL when no URL available")
  func requestPermissionNoURL() {
    let suite = testDefaults()
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
    let result = coordinator.requestPermissionIfNeededAndResolve()
    #expect(mockStrategy.requestPermissionCallCount == 1, "Should have called requestPermission once")
    #expect(result == .noURL(.safari), "Should return .noURL when no URL is available")
  }

  @Test("requestPermissionIfNeededAndResolve resolves URL without requesting when already allowed")
  func requestPermissionIfNeededAlreadyAllowed() {
    let suite = testDefaults()
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
    let result = coordinator.requestPermissionIfNeededAndResolve()
    #expect(mockStrategy.requestPermissionCallCount == 0, "Should NOT request permission when already allowed")
    #expect(result == .url(.safari, "example.com"), "Should resolve to URL when permission is allowed")
  }

  private func testDefaults() -> UserDefaults {
    let suite = TestDefaults.makeSuite()
    Defaults[.browserTabUnblockEnabled(suite: suite)] = true
    return suite
  }

  private func makeCoordinator(suite: UserDefaults) -> BrowserTabCoordinator {
    makeCoordinator(monitor: MockAppFocusMonitor(), suite: suite)
  }

  private func makeCoordinator(monitor: AppFocusMonitoring, suite: UserDefaults) -> BrowserTabCoordinator {
    BrowserTabCoordinator(
      monitor: monitor,
      urlFetcher: BrowserUrlFetcher(strategyFactory: MockUrlStrategyFactory()),
      strategyFactory: MockUrlStrategyFactory(),
      defaultsSuite: suite
    )
  }
}
