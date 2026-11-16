import Foundation
import Testing

@testable import HoleberryCore

@Suite("TestUserDefaults")
@MainActor
struct TestUserDefaultsTests {
  @Test func rejectedRemovalRetainsThePersistedValue() {
    let suite = TestUserDefaults()
    suite.set(["first"], forKey: "probe")
    suite.rejectedWriteKeys = ["probe"]

    suite.removeObject(forKey: "probe")

    #expect(suite.object(forKey: "probe") as? [String] == ["first"])
    #expect(suite.persistentDomain(forName: suite.domainName)?["probe"] as? [String] == ["first"])
  }

  @Test func acceptedRemovalDeletesThePersistedValue() {
    let suite = TestUserDefaults()
    suite.set(["first"], forKey: "probe")

    suite.removeObject(forKey: "probe")

    #expect(suite.object(forKey: "probe") == nil)
    #expect(suite.persistentDomain(forName: suite.domainName)?["probe"] == nil)
  }
}
