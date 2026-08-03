import Foundation

public protocol UrlFetchingStrategyFactory {
  func strategy(for browser: Browser) -> any BrowserActiveUrlFetchingStrategy
}

public struct BrowserActiveUrlFetchingStrategyFactory: UrlFetchingStrategyFactory {
  public let permissionChecker: any PermissionChecker
  public let scriptExecutor: any AppleScriptExecutor

  public init(
    permissionChecker: any PermissionChecker,
    scriptExecutor: any AppleScriptExecutor
  ) {
    self.permissionChecker = permissionChecker
    self.scriptExecutor = scriptExecutor
  }

  public func strategy(for browser: Browser) -> any BrowserActiveUrlFetchingStrategy {
    switch browser {
    case .safari, .safariTechnologyPreview:
      return SafariUrlFetchingStrategy(
        appName: browser.appName,
        permissionChecker: permissionChecker,
        scriptExecutor: scriptExecutor
      )
    case .firefox, .firefoxDeveloperEdition, .firefoxNightly:
      return GeckoSessionStoreUrlFetchingStrategy(supportDirName: "Firefox", category: "firefox-sessionstore")
    case .zen:
      return GeckoSessionStoreUrlFetchingStrategy(supportDirName: "zen", category: "zen-sessionstore")

    // Chromium-based browsers — all fall through to Chrome
    case .edge, .edgeBeta, .edgeDev, .edgeCanary,
      .brave, .braveBeta, .braveNightly,
      .arc,
      .opera, .operaNext, .operaDeveloper,
      .vivaldi, .vivaldiSnapshot,
      .chrome, .chromeBeta, .chromeDev, .chromeCanary:
      return ChromiumUrlFetchingStrategy(
        appName: browser.appName,
        permissionChecker: permissionChecker,
        scriptExecutor: scriptExecutor
      )

    default:
      fatalError("Unsupported browser: \(browser)")
    }
  }
}
