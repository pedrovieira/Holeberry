import Foundation
import Testing

@testable import HoleberryCore

@Suite("App deep links")
@MainActor
struct AppDeepLinkTests {
  @Test(arguments: ["holeberry://settings", "HOLEBERRY://SETTINGS", "holeberry://settings/"])
  func settingsDestinationIsAccepted(_ value: String) throws {
    let url = try #require(URL(string: value))
    #expect(AppDeepLink.isSettingsURL(url))
  }

  @Test(arguments: [
    "https://settings", "holeberry://other", "holeberry:settings", "holeberry://",
    "holeberry://settings.example", "holeberry://user@settings", "holeberry://settings:123",
    "holeberry://settings/other", "holeberry://settings?target=other", "holeberry://settings#other"
  ])
  func unrelatedOrMalformedDestinationIsRejected(_ value: String) throws {
    let url = try #require(URL(string: value))
    #expect(AppDeepLink.isSettingsURL(url) == false)
  }
}
