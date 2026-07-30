import Foundation

public struct ChromiumUrlFetchingStrategy: AppleScriptUrlFetchingStrategy {
  public let appName: String
  public let scriptCommand: String = "get URL of active tab of front window"
  public let permissionChecker: PermissionChecker
  public let scriptExecutor: AppleScriptExecutor

  public init(
    appName: String,
    permissionChecker: PermissionChecker = LivePermissionChecker(),
    scriptExecutor: AppleScriptExecutor = LiveAppleScriptExecutor()
  ) {
    self.appName = appName
    self.permissionChecker = permissionChecker
    self.scriptExecutor = scriptExecutor
  }
}
