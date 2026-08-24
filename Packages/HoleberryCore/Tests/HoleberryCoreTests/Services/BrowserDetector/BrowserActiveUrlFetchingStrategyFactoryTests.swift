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

  @Test("WebKit browsers use WebKitUrlFetchingStrategy")
  func webKitStrategy() {
    for browser in [Browser.safari, .safariTechnologyPreview, .orion, .orionRC] {
      let strategy = factory.strategy(for: browser)
      #expect(strategy is WebKitUrlFetchingStrategy)
    }
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

  @Test("Waterfox uses GeckoSessionStoreUrlFetchingStrategy")
  func waterfoxStrategy() {
    let strategy = factory.strategy(for: .waterfox)
    #expect(strategy is GeckoSessionStoreUrlFetchingStrategy)
  }

  @Test("Helium uses ChromiumUrlFetchingStrategy")
  func heliumStrategy() {
    let strategy = factory.strategy(for: .helium)
    #expect(strategy is ChromiumUrlFetchingStrategy)
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
        strategy is WebKitUrlFetchingStrategy
          || strategy is GeckoSessionStoreUrlFetchingStrategy
          || strategy is ChromiumUrlFetchingStrategy
      )
    }
  }
}
