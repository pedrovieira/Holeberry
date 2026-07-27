import Carbon
import Foundation

/// Abstracts the Carbon TCC permission check so it can be mocked in tests.
protocol PermissionChecker {
  /// Queries or requests the Automation permission for a target bundle.
  /// - Returns: `.allowed`, `.denied`, or `.notDetermined`.
  func checkPermission(for bundleID: String, askUserIfNeeded: Bool) -> AutomationPermission
}

/// The live implementation that calls the real Carbon `AEDeterminePermissionToAutomateTarget` API.
struct LivePermissionChecker: PermissionChecker {
  func checkPermission(for bundleID: String, askUserIfNeeded: Bool) -> AutomationPermission {
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
