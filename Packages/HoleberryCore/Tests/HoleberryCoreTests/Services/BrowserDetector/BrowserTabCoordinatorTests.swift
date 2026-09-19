import Defaults
import Foundation
import Testing

@testable import HoleberryCore

@Suite("BrowserTabCoordinator")
@MainActor
struct BrowserTabCoordinatorTests {
  @Test("returns .disabled when feature is off")
  func disabledWhenFeatureOff() {
    let suite = testDefaults(enableFeature: false)
    let coordinator = makeCoordinator(suite: suite)
    let result = coordinator.resolve()
    #expect(result == .disabled)
  }

  @Test("returns .noBrowser when no browser detected")
  func noBrowserWhenNoneDetected() {
    let suite = testDefaults()
    let coordinator = makeCoordinator(suite: suite)
    let result = coordinator.resolve()
    #expect(result == .noBrowser)
  }

  @Test("returns .permissionNeeded when permission not determined")
  func permissionNeeded() {
    let suite = testDefaults()
    let strategy = MockBrowserActiveUrlFetchingStrategy()
    strategy.stubbedAccessState = .notDetermined
    let coordinator = makeCoordinator(browser: .safari, strategy: strategy, suite: suite)
    let result = coordinator.resolve()
    #expect(result == .permissionNeeded(.safari))
  }

  @Test("returns .permissionDenied carrying the strategy's Automation pane")
  func permissionDeniedCarriesAutomationPane() {
    let suite = testDefaults()
    let strategy = MockBrowserActiveUrlFetchingStrategy()
    strategy.stubbedAccessState = .denied(.automation)
    let coordinator = makeCoordinator(browser: .chrome, strategy: strategy, suite: suite)
    let result = coordinator.resolve()
    #expect(result == .permissionDenied(.chrome, .automation))
  }

  @Test("a Gecko denial carries the Files & Folders pane")
  func geckoDeniedCarriesFilesAndFoldersPane() {
    let suite = testDefaults()
    let strategy = MockBrowserActiveUrlFetchingStrategy()
    strategy.stubbedAccessState = .denied(.filesAndFolders)
    let coordinator = makeCoordinator(browser: .firefox, strategy: strategy, suite: suite)
    let result = coordinator.resolve()
    #expect(result == .permissionDenied(.firefox, .filesAndFolders))
  }

  @Test("returns .url with domain when available")
  func urlResolved() {
    let suite = testDefaults()
    let strategy = MockBrowserActiveUrlFetchingStrategy()
    strategy.stubbedAccessState = .allowed
    strategy.stubbedURL = "https://example.com/page"
    let coordinator = makeCoordinator(browser: .safari, strategy: strategy, suite: suite)
    let result = coordinator.resolve()
    #expect(result == .url(.safari, "example.com"))
  }

  @Test("returns .noURL for an internal browser page")
  func internalPageReturnsNoURL() {
    let suite = testDefaults()
    let strategy = MockBrowserActiveUrlFetchingStrategy()
    strategy.stubbedURL = "chrome://settings"
    let coordinator = makeCoordinator(browser: .chrome, strategy: strategy, suite: suite)
    #expect(coordinator.resolve() == .noURL(.chrome))
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
    let coordinator = makeCoordinator(browser: .safari, suite: suite)
    #expect(coordinator.lastSeenBrowser == .safari, "Should return .safari when that browser is focused")
  }

  // MARK: - requestPermissionIfNeededAndResolve

  @Test("requestPermissionIfNeededAndResolve returns .disabled when feature is off")
  func requestPermissionDisabledWhenFeatureOff() {
    let suite = testDefaults(enableFeature: false)
    let coordinator = makeCoordinator(suite: suite)
    let result = coordinator.requestPermissionIfNeededAndResolve()
    #expect(result == .disabled, "Should return .disabled when browser tab unblock is disabled")
  }

  @Test("requestPermissionIfNeededAndResolve returns .noBrowser when no browser detected")
  func requestPermissionNoBrowser() {
    let suite = testDefaults()
    let coordinator = makeCoordinator(suite: suite)
    let result = coordinator.requestPermissionIfNeededAndResolve()
    #expect(result == .noBrowser, "Should return .noBrowser when no browser is focused")
  }

  @Test("requestPermissionIfNeededAndResolve asks the strategy and resolves URL when permission not determined")
  func requestPermissionPromptsAndResolves() {
    let suite = testDefaults()
    let strategy = MockBrowserActiveUrlFetchingStrategy()
    strategy.stubbedAccessStateQueue = [.notDetermined, .allowed]
    strategy.stubbedURL = "https://example.com/page"
    let coordinator = makeCoordinator(browser: .safari, strategy: strategy, suite: suite)
    let result = coordinator.requestPermissionIfNeededAndResolve()
    #expect(strategy.requestAccessCallCount == 1, "Should have asked the strategy once")
    #expect(result == .url(.safari, "example.com"), "Should resolve to URL after permission is granted")
  }

  @Test("requestPermissionIfNeededAndResolve does not ask the strategy when already denied")
  func requestPermissionDeniedDoesNotPrompt() {
    let suite = testDefaults()
    let strategy = MockBrowserActiveUrlFetchingStrategy()
    strategy.stubbedAccessState = .denied(.automation)
    strategy.stubbedURL = "https://example.com/page"
    let coordinator = makeCoordinator(browser: .chrome, strategy: strategy, suite: suite)
    let result = coordinator.requestPermissionIfNeededAndResolve()
    #expect(strategy.requestAccessCallCount == 0, "A denial cannot be re-prompted for either mechanism")
    #expect(result == .permissionDenied(.chrome, .automation), "Should stay denied and carry the pane")
  }

  @Test("requestPermissionIfNeededAndResolve returns the denied state when the prompt is rejected")
  func requestPermissionPromptRejected() {
    let suite = testDefaults()
    let strategy = MockBrowserActiveUrlFetchingStrategy()
    strategy.stubbedAccessStateQueue = [.notDetermined, .denied(.automation)]
    let coordinator = makeCoordinator(browser: .safari, strategy: strategy, suite: suite)
    let result = coordinator.requestPermissionIfNeededAndResolve()
    #expect(strategy.requestAccessCallCount == 1, "Should have asked the strategy once")
    #expect(result == .permissionDenied(.safari, .automation), "A rejected prompt resolves to the denied state")
  }

  @Test("requestPermissionIfNeededAndResolve returns .noURL when no URL available")
  func requestPermissionNoURL() {
    let suite = testDefaults()
    let strategy = MockBrowserActiveUrlFetchingStrategy()
    strategy.stubbedAccessStateQueue = [.notDetermined, .allowed]
    strategy.stubbedURL = nil
    let coordinator = makeCoordinator(browser: .safari, strategy: strategy, suite: suite)
    let result = coordinator.requestPermissionIfNeededAndResolve()
    #expect(strategy.requestAccessCallCount == 1, "Should have asked the strategy once")
    #expect(result == .noURL(.safari), "Should return .noURL when no URL is available")
  }

  @Test("requestPermissionIfNeededAndResolve resolves URL without asking when already allowed")
  func requestPermissionIfNeededAlreadyAllowed() {
    let suite = testDefaults()
    let strategy = MockBrowserActiveUrlFetchingStrategy()
    strategy.stubbedAccessState = .allowed
    strategy.stubbedURL = "https://example.com/page"
    let coordinator = makeCoordinator(browser: .safari, strategy: strategy, suite: suite)
    let result = coordinator.requestPermissionIfNeededAndResolve()
    #expect(strategy.requestAccessCallCount == 0, "Should NOT ask when permission is already allowed")
    #expect(result == .url(.safari, "example.com"), "Should resolve to URL when permission is allowed")
  }

  // MARK: - Helpers

  private func testDefaults(enableFeature: Bool = true) -> UserDefaults {
    let suite = TestDefaults.makeSuite()
    Defaults[.browserTabUnblockEnabled(suite: suite)] = enableFeature
    return suite
  }

  private func makeCoordinator(
    browser: Browser? = nil,
    strategy: MockBrowserActiveUrlFetchingStrategy = MockBrowserActiveUrlFetchingStrategy(),
    suite: UserDefaults
  ) -> BrowserTabCoordinator {
    let monitor = MockAppFocusMonitor()
    monitor.lastSeenBrowser = browser
    let factory = MockUrlStrategyFactory(mockStrategy: strategy)
    return BrowserTabCoordinator(
      monitor: monitor,
      strategyFactory: factory,
      defaultsSuite: suite
    )
  }
}
