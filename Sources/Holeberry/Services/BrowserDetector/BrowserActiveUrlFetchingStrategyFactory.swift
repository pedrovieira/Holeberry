import Foundation

struct BrowserActiveUrlFetchingStrategyFactory {
  func strategy(for browser: Browser) -> BrowserActiveUrlFetchingStrategy {
    switch browser {
    case .safari, .safariTechnologyPreview:
      return SafariUrlFetchingStrategy(appName: browser.appName)
    case .firefox, .firefoxDeveloperEdition, .firefoxNightly:
      return FirefoxSessionStoreUrlFetchingStrategy()
    default:
      return ChromiumUrlFetchingStrategy(appName: browser.appName)
    }
  }
}
