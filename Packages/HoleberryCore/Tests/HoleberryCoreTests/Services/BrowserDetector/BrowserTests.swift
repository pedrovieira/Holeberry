import Foundation
import Testing

@testable import HoleberryCore

@Suite("Browser")
struct BrowserTests {
  @Test("all browsers have valid bundle IDs")
  func allHaveBundleIDs() {
    for browser in Browser.allCases {
      #expect(browser.bundleID.isEmpty == false)
      #expect(browser.appName.isEmpty == false)
    }
  }
}
