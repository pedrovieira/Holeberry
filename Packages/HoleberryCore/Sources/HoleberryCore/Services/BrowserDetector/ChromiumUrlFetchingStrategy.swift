import Foundation

public struct ChromiumUrlFetchingStrategy: AppleScriptUrlFetchingStrategy {
  public let browser: Browser
  public let scriptCommand: String = "get URL of active tab of front window"
  public let permissionChecker: any PermissionChecker
  public let scriptExecutor: any AppleScriptExecutor

  public init(
    browser: Browser,
    permissionChecker: any PermissionChecker,
    scriptExecutor: any AppleScriptExecutor
  ) {
    self.browser = browser
    self.permissionChecker = permissionChecker
    self.scriptExecutor = scriptExecutor
  }
}
