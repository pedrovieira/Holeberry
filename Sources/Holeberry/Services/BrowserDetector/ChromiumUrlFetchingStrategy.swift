import Foundation

struct ChromiumUrlFetchingStrategy: AppleScriptUrlFetchingStrategy {
  let appName: String
  let scriptCommand: String = "get URL of active tab of front window"
  let permissionChecker: PermissionChecker
  let scriptExecutor: AppleScriptExecutor

  init(
    appName: String,
    permissionChecker: PermissionChecker = LivePermissionChecker(),
    scriptExecutor: AppleScriptExecutor = LiveAppleScriptExecutor()
  ) {
    self.appName = appName
    self.permissionChecker = permissionChecker
    self.scriptExecutor = scriptExecutor
  }
}
