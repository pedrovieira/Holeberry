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
    case .safari, .safariTechnologyPreview, .orion, .orionRC:
      return WebKitUrlFetchingStrategy(
        browser: browser,
        permissionChecker: permissionChecker,
        scriptExecutor: scriptExecutor
      )
    case .firefox, .firefoxDeveloperEdition, .firefoxNightly:
      return GeckoSessionStoreUrlFetchingStrategy(
        browser: browser,
        supportDirName: "Firefox",
        category: "firefox-sessionstore"
      )
    case .zen:
      return GeckoSessionStoreUrlFetchingStrategy(
        browser: browser,
        supportDirName: "zen",
        category: "zen-sessionstore"
      )
    case .waterfox:
      return GeckoSessionStoreUrlFetchingStrategy(
        browser: browser,
        supportDirName: "Waterfox",
        category: "waterfox-sessionstore"
      )
    case .floorp:
      return GeckoSessionStoreUrlFetchingStrategy(
        browser: browser,
        supportDirName: "Floorp",
        category: "floorp-sessionstore"
      )

    // Browsers whose scripting dictionary defines the Chromium active-tab command.
    // Yab is hybrid (WebKit and Chromium) but uses the same expression for both engines.
    case .chromium,
      .edge, .edgeBeta, .edgeDev, .edgeCanary,
      .brave, .braveBeta, .braveNightly,
      .arc, .dia,
      .ardia,
      .yab, .yabDev,
      .opera, .operaNext, .operaDeveloper, .operaGX, .operaNeon, .operaAir,
      .comet,
      .yandex,
      .ecosia,
      .vivaldi, .vivaldiSnapshot,
      .helium,
      .chrome, .chromeBeta, .chromeDev, .chromeCanary:
      return ChromiumUrlFetchingStrategy(
        browser: browser,
        permissionChecker: permissionChecker,
        scriptExecutor: scriptExecutor
      )

    default:
      fatalError("Unsupported browser: \(browser)")
    }
  }
}
