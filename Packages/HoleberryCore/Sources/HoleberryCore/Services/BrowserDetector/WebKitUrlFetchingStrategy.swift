import Foundation

public struct WebKitUrlFetchingStrategy: AppleScriptUrlFetchingStrategy {
  public let browser: Browser
  public let scriptCommand: String = "get URL of front document"
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
