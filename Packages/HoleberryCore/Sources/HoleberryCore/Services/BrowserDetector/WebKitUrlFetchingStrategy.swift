import Foundation

public struct WebKitUrlFetchingStrategy: AppleScriptUrlFetchingStrategy {
  public let appName: String
  public let scriptCommand: String = "get URL of front document"
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
