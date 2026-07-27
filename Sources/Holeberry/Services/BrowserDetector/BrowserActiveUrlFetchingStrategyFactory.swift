import Foundation

protocol UrlFetchingStrategyFactory {
  func strategy(for browser: Browser) -> BrowserActiveUrlFetchingStrategy
}

struct BrowserActiveUrlFetchingStrategyFactory: UrlFetchingStrategyFactory {
  let permissionChecker: PermissionChecker
  let scriptExecutor: AppleScriptExecutor

  func strategy(for browser: Browser) -> BrowserActiveUrlFetchingStrategy {
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
