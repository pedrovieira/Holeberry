import Foundation

public struct ChromiumUrlFetchingStrategy: AppleScriptUrlFetchingStrategy {
  public let appName: String
  public let scriptCommand: String = "get URL of active tab of front window"
  public let permissionChecker: any PermissionChecker
  public let scriptExecutor: any AppleScriptExecutor

  public init(
    appName: String,
    permissionChecker: any PermissionChecker,
    scriptExecutor: any AppleScriptExecutor
  ) {
    self.appName = appName
    self.permissionChecker = permissionChecker
    self.scriptExecutor = scriptExecutor
  }
}
