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

  @Test("Ardia is recognized by its release bundle ID and named Ardia")
  func ardiaIdentity() {
    #expect(Browser.ardia.bundleID == "com.ardia.browser")
    #expect(Browser.ardia.appName == "Ardia")
    #expect(Browser(rawValue: "com.ardia.browser") == .ardia)
  }

  @Test("Yab release and development builds are recognized by their bundle IDs")
  func yabIdentities() {
    #expect(Browser.yab.bundleID == "dev.serafim.fast")
    #expect(Browser.yab.appName == "Yab")
    #expect(Browser.yabDev.bundleID == "dev.serafim.fast.dev")
    #expect(Browser.yabDev.appName == "Yab Dev")
    #expect(Browser(rawValue: "dev.serafim.fast") == .yab)
    #expect(Browser(rawValue: "dev.serafim.fast.dev") == .yabDev)
  }

  @Test("Floorp is recognized by its stable bundle ID and named Floorp")
  func floorpIdentity() {
    #expect(Browser.floorp.bundleID == "app.floorp.Floorp")
    #expect(Browser.floorp.appName == "Floorp")
    #expect(Browser(rawValue: "app.floorp.Floorp") == .floorp)
  }
}
