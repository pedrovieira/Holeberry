import Foundation
import Testing

@testable import HoleberryCore

// swiftlint:disable type_name

@Suite("BrowserActiveUrlFetchingStrategyFactory")
struct BrowserActiveUrlFetchingStrategyFactoryTests {
  private let factory = BrowserActiveUrlFetchingStrategyFactory(
    permissionChecker: LivePermissionChecker(),
    scriptExecutor: LiveAppleScriptExecutor()
  )

  @Test("Safari uses SafariUrlFetchingStrategy")
  func safariStrategy() {
    let strategy = factory.strategy(for: .safari)
    #expect(strategy is SafariUrlFetchingStrategy)
  }

  @Test("Chrome uses ChromiumUrlFetchingStrategy")
  func chromeStrategy() {
    let strategy = factory.strategy(for: .chrome)
    #expect(strategy is ChromiumUrlFetchingStrategy)
  }

  @Test("Firefox uses GeckoSessionStoreUrlFetchingStrategy")
  func firefoxStrategy() {
    let strategy = factory.strategy(for: .firefox)
    #expect(strategy is GeckoSessionStoreUrlFetchingStrategy)
  }

  @Test("Zen uses GeckoSessionStoreUrlFetchingStrategy")
  func zenStrategy() {
    let strategy = factory.strategy(for: .zen)
    #expect(strategy is GeckoSessionStoreUrlFetchingStrategy)
  }

  @Test("Arc uses ChromiumUrlFetchingStrategy")
  func arcStrategy() {
    let strategy = factory.strategy(for: .arc)
    #expect(strategy is ChromiumUrlFetchingStrategy)
  }

  @Test("Factory supports every browser case without crashing")
  func allBrowsersSupported() {
    for browser in Browser.allCases {
      let strategy = factory.strategy(for: browser)
      #expect(
        strategy is SafariUrlFetchingStrategy
          || strategy is GeckoSessionStoreUrlFetchingStrategy
          || strategy is ChromiumUrlFetchingStrategy
      )
    }
  }
}
