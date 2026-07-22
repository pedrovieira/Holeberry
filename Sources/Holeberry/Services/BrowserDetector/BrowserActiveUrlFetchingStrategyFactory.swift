import Foundation

protocol UrlFetchingStrategyFactory {
  func strategy(for browser: Browser) -> BrowserActiveUrlFetchingStrategy
}

struct BrowserActiveUrlFetchingStrategyFactory: UrlFetchingStrategyFactory {
  func strategy(for browser: Browser) -> BrowserActiveUrlFetchingStrategy {
    switch browser {
    case .safari, .safariTechnologyPreview:
      return SafariUrlFetchingStrategy(appName: browser.appName)
    case .firefox, .firefoxDeveloperEdition, .firefoxNightly:
      return GeckoSessionStoreUrlFetchingStrategy(supportDirName: "Firefox", category: "firefox-sessionstore")
    case .zen:
      return GeckoSessionStoreUrlFetchingStrategy(supportDirName: "zen", category: "zen-sessionstore")
    default:
      return ChromiumUrlFetchingStrategy(appName: browser.appName)
    }
  }
}
