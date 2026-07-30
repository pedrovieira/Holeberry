import Foundation

public struct SafariUrlFetchingStrategy: AppleScriptUrlFetchingStrategy {
  public let appName: String
  public let scriptCommand: String = "get URL of front document"
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
