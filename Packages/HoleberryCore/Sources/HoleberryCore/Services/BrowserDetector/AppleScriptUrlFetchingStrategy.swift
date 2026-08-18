import Foundation
import OSLog

// MARK: - AppleScript URL fetching strategy

/// A refinement of `BrowserActiveUrlFetchingStrategy` for browsers whose
/// active URL can be obtained via AppleScript.
public protocol AppleScriptUrlFetchingStrategy: BrowserActiveUrlFetchingStrategy {
  /// The `application` name used in the `tell` block, e.g. "Safari" or "Orion".
  var appName: String { get }

  /// The AppleScript command that returns the frontmost URL, e.g.
  /// `"get URL of front document"`.
  var scriptCommand: String { get }

  /// The permission checker used to determine TCC Automation access.
  var permissionChecker: any PermissionChecker { get }

  /// The AppleScript executor used to compile and run scripts.
  var scriptExecutor: any AppleScriptExecutor { get }
}

// MARK: - Default implementations

extension AppleScriptUrlFetchingStrategy {
  private var logger: Logger {
    Logger(subsystem: Logger.appSubsystem, category: "applescript")
  }

  public func getCurrentURL(for browser: Browser) -> String? {
    let script = """
      tell application "\(appName)"
        if (count of windows) > 0 then
          \(scriptCommand)
        end if
      end tell
      """

    let (result, error) = scriptExecutor.execute(script)
    guard let result else {
      logger.warning("AppleScript init failed for \(browser.bundleID)")
      return nil
    }

    if let error {
      let errorNumber = (error[NSAppleScript.errorNumber] as? Int) ?? -1
      if errorNumber == -1743 {
        logger.notice("AppleScript permission denied for \(browser.bundleID)")
        return nil  // signals permission denied (nil vs empty string)
      }
      logger.warning("AppleScript error for \(browser.bundleID): \(error, privacy: .public)")
      return ""
    }

    return result.stringValue ?? ""
  }

  // MARK: - Permission

  public func isPermissionGranted(for browser: Browser) -> AutomationPermission {
    permissionChecker.checkPermission(for: browser.bundleID, askUserIfNeeded: false)
  }

  public func requestPermission(for browser: Browser) {
    _ = permissionChecker.checkPermission(for: browser.bundleID, askUserIfNeeded: true)
  }
}
