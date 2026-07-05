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
    requestPermissionIfNeeded(for: browser.bundleID)

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

  /// Triggers the Automation permission prompt via the proper TCC API,
  /// which works from any calling context (menu item, keyboard shortcut, etc.).
  private func requestPermissionIfNeeded(for bundleID: String) {
    var target = AEAddressDesc()
    let createStatus = bundleID.withCString { cString in
      AECreateDesc(
        typeApplicationBundleID,
        cString,
        strlen(cString),
        &target
      )
    }
    guard createStatus == noErr else { return }
    defer { AEDisposeDesc(&target) }

    // kAECoreSuite = 'core', kAEGetData = 'getd'
    _ = AEDeterminePermissionToAutomateTarget(
      &target,
      0x636F_7265,  // 'core'
      0x6765_7464,  // 'getd'
      true  // askUserIfNeeded
    )
  }
}
