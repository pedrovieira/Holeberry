import Foundation
import Testing

@testable import Holeberry

@Suite("Browser")
struct BrowserTests {
  @Test("all browsers have valid bundle IDs")
  func allHaveBundleIDs() {
    for browser in Browser.allCases {
      #expect(!browser.bundleID.isEmpty)
      #expect(!browser.appName.isEmpty)
    }
  }
}
