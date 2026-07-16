import AppKit
import Carbon
import Foundation
import OSLog

class AppleScriptUrlFetchingStrategy: BrowserActiveUrlFetchingStrategy {
  private let appName: String
  private let scriptCommand: String
  private let logger = Logger(subsystem: Logger.appSubsystem, category: "applescript")

  init(appName: String, scriptCommand: String) {
    self.appName = appName
    self.scriptCommand = scriptCommand
  }

  func getCurrentURL(for browser: Browser) -> String? {
    let script = """
      tell application "\(appName)"
        if (count of windows) > 0 then
          \(scriptCommand)
        end if
      end tell
      """

    var error: NSDictionary?
    let appleScript = NSAppleScript(source: script)
    guard let result = appleScript?.executeAndReturnError(&error) else {
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

  func isPermissionGranted(for browser: Browser) -> AutomationPermission {
    resolvePermission(for: browser.bundleID, askUserIfNeeded: false)
  }

  func requestPermission(for browser: Browser) {
    _ = resolvePermission(for: browser.bundleID, askUserIfNeeded: true)
  }

  /// Queries or requests the TCC Automation permission for a target bundle.
  /// - Returns: `.allowed`, `.denied`, or `.notDetermined`.
  private func resolvePermission(for bundleID: String, askUserIfNeeded: Bool) -> AutomationPermission {
    var target = AEAddressDesc()
    let createStatus = bundleID.withCString { cString in
      AECreateDesc(
        typeApplicationBundleID,
        cString,
        strlen(cString),
        &target
      )
    }
    guard createStatus == noErr else { return .denied }
    defer { AEDisposeDesc(&target) }

    // kAECoreSuite = 'core', kAEGetData = 'getd'
    let result = AEDeterminePermissionToAutomateTarget(
      &target,
      0x636F_7265,  // 'core'
      0x6765_7464,  // 'getd'
      askUserIfNeeded
    )
    if result == noErr { return .allowed }
    if result == errAEEventNotPermitted { return .denied }
    return .notDetermined
  }
}
