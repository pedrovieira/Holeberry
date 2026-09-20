import Foundation
import OSLog

// MARK: - AppleScript URL fetching strategy

/// A refinement of `BrowserActiveUrlFetchingStrategy` for browsers whose
/// active URL can be obtained via AppleScript.
public protocol AppleScriptUrlFetchingStrategy: BrowserActiveUrlFetchingStrategy {
  /// The AppleScript command that returns the frontmost URL, e.g.
  /// `"get URL of front document"`.
  var scriptCommand: String { get }

  /// The permission checker used to determine Automation access.
  var permissionChecker: any PermissionChecker { get }

  /// The AppleScript executor used to compile and run scripts.
  var scriptExecutor: any AppleScriptExecutor { get }
}

// MARK: - Default implementations

extension AppleScriptUrlFetchingStrategy {
  private var logger: Logger {
    Logger(subsystem: Logger.appSubsystem, category: "applescript")
  }

  public func getCurrentURL() -> URL? {
    let script = """
      tell application "\(browser.appName)"
        if (count of windows) > 0 then
          \(scriptCommand)
        end if
      end tell
      """

    let (result, error) = scriptExecutor.execute(script)
    guard let result else {
      logger.warning("AppleScript init failed for \(self.browser.bundleID)")
      return nil
    }

    if let error {
      let errorNumber = (error[NSAppleScript.errorNumber] as? Int) ?? -1
      if errorNumber == -1743 {
        logger.notice("AppleScript permission denied for \(self.browser.bundleID)")
        return nil
      }
      logger.warning("AppleScript error for \(self.browser.bundleID): \(error, privacy: .public)")
      return nil
    }

    guard let stringValue = result.stringValue else { return nil }
    return URL(string: stringValue)
  }

  // MARK: - Permission

  public func accessState() -> BrowserAccessState {
    switch permissionChecker.checkPermission(for: browser.bundleID, askUserIfNeeded: false) {
    case .allowed:
      return .allowed
    case .denied:
      return .denied(.automation)
    case .notDetermined:
      return .notDetermined
    }
  }

  public func requestAccess() {
    _ = permissionChecker.checkPermission(for: browser.bundleID, askUserIfNeeded: true)
  }
}
