import Foundation
import Testing

@testable import HoleberryCore

private enum AppleScriptStrategyCase: Sendable {
  case chromium(Browser)
  case webkit(Browser)

  var browser: Browser {
    switch self {
    case .chromium(let browser), .webkit(let browser): browser
    }
  }

  var expectedScriptCommand: String {
    switch self {
    case .chromium: "get URL of active tab of front window"
    case .webkit: "get URL of front document"
    }
  }

  func makeStrategy(
    permissionChecker: any PermissionChecker,
    scriptExecutor: any AppleScriptExecutor
  ) -> any AppleScriptUrlFetchingStrategy {
    switch self {
    case .chromium(let browser):
      ChromiumUrlFetchingStrategy(
        browser: browser,
        permissionChecker: permissionChecker,
        scriptExecutor: scriptExecutor)
    case .webkit(let browser):
      WebKitUrlFetchingStrategy(browser: browser, permissionChecker: permissionChecker, scriptExecutor: scriptExecutor)
    }
  }
}

private let testCases: [AppleScriptStrategyCase] = [
  .chromium(.chrome),
  .chromium(.edgeCanary),
  .chromium(.brave),
  .chromium(.arc),
  .chromium(.vivaldiSnapshot),
  .webkit(.safari),
  .webkit(.safariTechnologyPreview),
  .webkit(.orion),
  .webkit(.orionRC)
]

// MARK: - Tests

@Suite("AppleScript URL fetching strategies")
struct AppleScriptUrlFetchingStrategyTests {
  // MARK: - Properties

  @Test("Returns correct scriptCommand", arguments: testCases)
  private func returnsCorrectScriptCommand(testCase: AppleScriptStrategyCase) {
    let strategy = testCase.makeStrategy(
      permissionChecker: MockPermissionChecker(),
      scriptExecutor: MockAppleScriptExecutor())
    #expect(strategy.scriptCommand == testCase.expectedScriptCommand)
  }

  @Test("Targets the browser's application in the tell block", arguments: testCases)
  private func targetsBrowserApplication(testCase: AppleScriptStrategyCase) {
    let executor = MockAppleScriptExecutor()
    let strategy = testCase.makeStrategy(
      permissionChecker: MockPermissionChecker(),
      scriptExecutor: executor)
    _ = strategy.getCurrentURL()
    #expect(executor.lastSource?.contains("tell application \"\(testCase.browser.appName)\"") == true)
  }

  // MARK: - AppleScript execution

  @Test("Returns nil when AppleScript init fails")
  func initFailureReturnsNil() {
    let mockExecutor = MockAppleScriptExecutor()
    let strategy = ChromiumUrlFetchingStrategy(
      browser: .chrome,
      permissionChecker: MockPermissionChecker(),
      scriptExecutor: mockExecutor)
    #expect(strategy.getCurrentURL() == nil)
  }

  @Test("Returns nil when AppleScript permission is denied (error -1743)")
  func permissionDeniedReturnsNil() {
    let mockExecutor = MockAppleScriptExecutor()
    let descriptor = NSAppleEventDescriptor(string: "some value")
    mockExecutor.stubbedResult = descriptor
    mockExecutor.stubbedError = [NSAppleScript.errorNumber: -1743]
    let strategy = ChromiumUrlFetchingStrategy(
      browser: .chrome,
      permissionChecker: MockPermissionChecker(),
      scriptExecutor: mockExecutor)
    #expect(strategy.getCurrentURL() == nil)
  }

  @Test("Returns nil on AppleScript execution error")
  func executionErrorReturnsNil() {
    let mockExecutor = MockAppleScriptExecutor()
    let descriptor = NSAppleEventDescriptor(string: "some value")
    mockExecutor.stubbedResult = descriptor
    mockExecutor.stubbedError = [NSAppleScript.errorNumber: -1753]
    let strategy = ChromiumUrlFetchingStrategy(
      browser: .chrome,
      permissionChecker: MockPermissionChecker(),
      scriptExecutor: mockExecutor)
    #expect(strategy.getCurrentURL() == nil)
  }

  @Test("Returns the URL on successful execution")
  func successReturnsURL() {
    let mockExecutor = MockAppleScriptExecutor()
    mockExecutor.stubbedResult = NSAppleEventDescriptor(string: "https://example.com/page")
    let strategy = ChromiumUrlFetchingStrategy(
      browser: .chrome,
      permissionChecker: MockPermissionChecker(),
      scriptExecutor: mockExecutor)
    #expect(strategy.getCurrentURL() == URL(string: "https://example.com/page"))
  }

  @Test("Returns nil when result.stringValue is nil")
  func nilStringValueReturnsNil() {
    let mockExecutor = MockAppleScriptExecutor()
    // NSAppleEventDescriptor with no string value
    mockExecutor.stubbedResult = NSAppleEventDescriptor.list()
    let strategy = ChromiumUrlFetchingStrategy(
      browser: .chrome,
      permissionChecker: MockPermissionChecker(),
      scriptExecutor: mockExecutor)
    #expect(strategy.getCurrentURL() == nil)
  }

  // MARK: - Permission checking

  @Test("Returns allowed when permission check returns .allowed")
  func permissionAllowed() {
    let mockChecker = MockPermissionChecker()
    mockChecker.stubbedPermission = .allowed
    let strategy = ChromiumUrlFetchingStrategy(
      browser: .chrome,
      permissionChecker: mockChecker,
      scriptExecutor: MockAppleScriptExecutor())
    #expect(strategy.accessState() == .allowed)
  }

  @Test("Maps a denied permission check to the Automation pane")
  func permissionDenied() {
    let mockChecker = MockPermissionChecker()
    mockChecker.stubbedPermission = .denied
    let strategy = ChromiumUrlFetchingStrategy(
      browser: .chrome,
      permissionChecker: mockChecker,
      scriptExecutor: MockAppleScriptExecutor())
    #expect(strategy.accessState() == .denied(.automation))
  }

  @Test("Returns notDetermined when permission check returns .notDetermined")
  func permissionNotDetermined() {
    let mockChecker = MockPermissionChecker()
    mockChecker.stubbedPermission = .notDetermined
    let strategy = ChromiumUrlFetchingStrategy(
      browser: .chrome,
      permissionChecker: mockChecker,
      scriptExecutor: MockAppleScriptExecutor())
    #expect(strategy.accessState() == .notDetermined)
  }

  @Test("Access state delegates to checker with askUserIfNeeded=false")
  func accessStatePassesAskUserIfNeeded() {
    let mockChecker = MockPermissionChecker()
    let strategy = ChromiumUrlFetchingStrategy(
      browser: .chrome,
      permissionChecker: mockChecker,
      scriptExecutor: MockAppleScriptExecutor())
    _ = strategy.accessState()
    #expect(mockChecker.lastAskUserIfNeeded == false)
    #expect(mockChecker.checkPermissionCallCount == 1)
  }

  @Test("Passes correct bundleID to permission checker")
  func permissionCheckerReceivesCorrectBundleID() {
    let mockChecker = MockPermissionChecker()
    let strategy = ChromiumUrlFetchingStrategy(
      browser: .chrome,
      permissionChecker: mockChecker,
      scriptExecutor: MockAppleScriptExecutor())
    _ = strategy.accessState()
    #expect(mockChecker.lastBundleID == Browser.chrome.bundleID)
  }

  @Test("requestAccess delegates to checker with askUserIfNeeded=true")
  func requestAccessPassesAskUserIfNeeded() {
    let mockChecker = MockPermissionChecker()
    let strategy = ChromiumUrlFetchingStrategy(
      browser: .chrome,
      permissionChecker: mockChecker,
      scriptExecutor: MockAppleScriptExecutor())
    strategy.requestAccess()
    #expect(mockChecker.lastAskUserIfNeeded == true)
    #expect(mockChecker.checkPermissionCallCount == 1)
    #expect(mockChecker.lastBundleID == Browser.chrome.bundleID)
  }
}
