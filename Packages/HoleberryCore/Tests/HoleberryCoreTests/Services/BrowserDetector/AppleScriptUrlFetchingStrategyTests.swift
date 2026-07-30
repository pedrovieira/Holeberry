import Foundation
import Testing

@testable import HoleberryCore

private enum AppleScriptStrategyCase: Sendable {
  case chromium(appName: String)
  case safari(appName: String)

  var expectedScriptCommand: String {
    switch self {
    case .chromium: "get URL of active tab of front window"
    case .safari: "get URL of front document"
    }
  }

  func makeStrategy(
    permissionChecker: PermissionChecker = LivePermissionChecker(),
    scriptExecutor: AppleScriptExecutor = LiveAppleScriptExecutor()
  ) -> any AppleScriptUrlFetchingStrategy {
    switch self {
    case .chromium(let appName):
      ChromiumUrlFetchingStrategy(
        appName: appName,
        permissionChecker: permissionChecker,
        scriptExecutor: scriptExecutor)
    case .safari(let appName):
      SafariUrlFetchingStrategy(appName: appName, permissionChecker: permissionChecker, scriptExecutor: scriptExecutor)
    }
  }
}

private let testCases: [AppleScriptStrategyCase] = [
  .chromium(appName: "Google Chrome"),
  .chromium(appName: "Microsoft Edge Canary"),
  .chromium(appName: "Brave Browser"),
  .chromium(appName: "Arc"),
  .chromium(appName: "Vivaldi Snapshot"),
  .safari(appName: "Safari"),
  .safari(appName: "Safari Technology Preview")
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

  @Test("Returns the appName it was initialized with", arguments: testCases)
  private func returnsAppName(testCase: AppleScriptStrategyCase) {
    let strategy = testCase.makeStrategy(
      permissionChecker: MockPermissionChecker(),
      scriptExecutor: MockAppleScriptExecutor())
    switch testCase {
    case .chromium(let expectedName):
      #expect(strategy.appName == expectedName)
    case .safari(let expectedName):
      #expect(strategy.appName == expectedName)
    }
  }

  // MARK: - AppleScript execution

  @Test("Returns nil when AppleScript init fails")
  func initFailureReturnsNil() {
    let mockExecutor = MockAppleScriptExecutor()
    let strategy = ChromiumUrlFetchingStrategy(appName: "Test", scriptExecutor: mockExecutor)
    #expect(strategy.getCurrentURL(for: .chrome) == nil)
  }

  @Test("Returns nil when AppleScript permission is denied (error -1743)")
  func permissionDeniedReturnsNil() {
    let mockExecutor = MockAppleScriptExecutor()
    let descriptor = NSAppleEventDescriptor(string: "some value")
    mockExecutor.stubbedResult = descriptor
    mockExecutor.stubbedError = [NSAppleScript.errorNumber: -1743]
    let strategy = ChromiumUrlFetchingStrategy(appName: "Test", scriptExecutor: mockExecutor)
    #expect(strategy.getCurrentURL(for: .chrome) == nil)
  }

  @Test("Returns empty string on AppleScript execution error")
  func executionErrorReturnsEmpty() {
    let mockExecutor = MockAppleScriptExecutor()
    let descriptor = NSAppleEventDescriptor(string: "some value")
    mockExecutor.stubbedResult = descriptor
    mockExecutor.stubbedError = [NSAppleScript.errorNumber: -1753]
    let strategy = ChromiumUrlFetchingStrategy(appName: "Test", scriptExecutor: mockExecutor)
    #expect(strategy.getCurrentURL(for: .chrome)?.isEmpty == true)
  }

  @Test("Returns URL string on successful execution")
  func successReturnsURL() {
    let mockExecutor = MockAppleScriptExecutor()
    mockExecutor.stubbedResult = NSAppleEventDescriptor(string: "https://example.com/page")
    let strategy = ChromiumUrlFetchingStrategy(appName: "Test", scriptExecutor: mockExecutor)
    #expect(strategy.getCurrentURL(for: .chrome) == "https://example.com/page")
  }

  @Test("Returns empty string when result.stringValue is nil")
  func nilStringValueReturnsEmpty() {
    let mockExecutor = MockAppleScriptExecutor()
    // NSAppleEventDescriptor with no string value
    mockExecutor.stubbedResult = NSAppleEventDescriptor.list()
    let strategy = ChromiumUrlFetchingStrategy(appName: "Test", scriptExecutor: mockExecutor)
    #expect(strategy.getCurrentURL(for: .chrome)?.isEmpty == true)
  }

  // MARK: - Permission checking

  @Test("Returns allowed when permission check returns .allowed")
  func permissionAllowed() {
    let mockChecker = MockPermissionChecker()
    mockChecker.stubbedPermission = .allowed
    let strategy = ChromiumUrlFetchingStrategy(appName: "Test", permissionChecker: mockChecker)
    #expect(strategy.isPermissionGranted(for: .chrome) == .allowed)
  }

  @Test("Returns denied when permission check returns .denied")
  func permissionDenied() {
    let mockChecker = MockPermissionChecker()
    mockChecker.stubbedPermission = .denied
    let strategy = ChromiumUrlFetchingStrategy(appName: "Test", permissionChecker: mockChecker)
    #expect(strategy.isPermissionGranted(for: .chrome) == .denied)
  }

  @Test("Returns notDetermined when permission check returns .notDetermined")
  func permissionNotDetermined() {
    let mockChecker = MockPermissionChecker()
    mockChecker.stubbedPermission = .notDetermined
    let strategy = ChromiumUrlFetchingStrategy(appName: "Test", permissionChecker: mockChecker)
    #expect(strategy.isPermissionGranted(for: .chrome) == .notDetermined)
  }

  @Test("Request permission delegates to checker with askUserIfNeeded=true")
  func requestPermissionPassesAskUserIfNeeded() {
    let mockChecker = MockPermissionChecker()
    let strategy = ChromiumUrlFetchingStrategy(appName: "Test", permissionChecker: mockChecker)
    strategy.requestPermission(for: .chrome)
    #expect(mockChecker.lastAskUserIfNeeded == true)
    #expect(mockChecker.checkPermissionCallCount == 1)
  }

  @Test("IsPermissionGranted delegates to checker with askUserIfNeeded=false")
  func isPermissionGrantedPassesAskUserIfNeeded() {
    let mockChecker = MockPermissionChecker()
    let strategy = ChromiumUrlFetchingStrategy(appName: "Test", permissionChecker: mockChecker)
    _ = strategy.isPermissionGranted(for: .chrome)
    #expect(mockChecker.lastAskUserIfNeeded == false)
    #expect(mockChecker.checkPermissionCallCount == 1)
  }

  @Test("Passes correct bundleID to permission checker")
  func permissionCheckerReceivesCorrectBundleID() {
    let mockChecker = MockPermissionChecker()
    let strategy = ChromiumUrlFetchingStrategy(appName: "Test", permissionChecker: mockChecker)
    _ = strategy.isPermissionGranted(for: .chrome)
    #expect(mockChecker.lastBundleID == Browser.chrome.bundleID)
  }
}
