import Foundation

/// Abstracts `NSAppleScript` execution so it can be mocked in tests.
protocol AppleScriptExecutor {
  /// Compiles and executes the AppleScript source.
  /// - Returns: A tuple of (result descriptor, error dictionary). Both are
  ///   `nil` if the source could not be compiled at all.
  func execute(_ source: String) -> (result: NSAppleEventDescriptor?, error: NSDictionary?)
}

/// The live implementation that uses `NSAppleScript` to compile and run scripts.
struct LiveAppleScriptExecutor: AppleScriptExecutor {
  func execute(_ source: String) -> (result: NSAppleEventDescriptor?, error: NSDictionary?) {
    let appleScript = NSAppleScript(source: source)
    var error: NSDictionary?
    let result = appleScript?.executeAndReturnError(&error)
    return (result, error)
  }
}
