import Foundation

@testable import HoleberryCore

final class MockAppleScriptExecutor: AppleScriptExecutor {
  var stubbedResult: NSAppleEventDescriptor?
  var stubbedError: NSDictionary?
  private(set) var executeCallCount = 0
  private(set) var lastSource: String?

  func execute(_ source: String) -> (result: NSAppleEventDescriptor?, error: NSDictionary?) {
    executeCallCount += 1
    lastSource = source
    return (stubbedResult, stubbedError)
  }
}
