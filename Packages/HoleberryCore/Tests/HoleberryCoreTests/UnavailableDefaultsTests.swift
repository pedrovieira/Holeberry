import Foundation
import Testing

@testable import HoleberryCore

@Suite("Unavailable defaults")
@MainActor
struct UnavailableDefaultsTests {
  @Test func domainAndDictionaryReadsHidePersistedValues() throws {
    let (name, control) = TestDefaults.makeNamedSuite()
    defer { control.removePersistentDomain(forName: name) }
    let unavailable = try #require(UnavailableDefaults(suiteName: name))
    control.set("saved", forKey: "probe")

    #expect(unavailable.persistentDomain(forName: name) == nil)
    #expect(unavailable.dictionaryRepresentation().isEmpty)
    #expect(control.string(forKey: "probe") == "saved")
  }

  @Test func domainReplacementPreservesPersistedValues() throws {
    let (name, control) = TestDefaults.makeNamedSuite()
    defer { control.removePersistentDomain(forName: name) }
    let unavailable = try #require(UnavailableDefaults(suiteName: name))
    control.set("saved", forKey: "probe")

    unavailable.setPersistentDomain(["probe": "replaced", "new": "leaked"], forName: name)

    #expect(control.persistentDomain(forName: name) as? [String: String] == ["probe": "saved"])
  }

  @Test func domainRemovalPreservesPersistedValues() throws {
    let (name, control) = TestDefaults.makeNamedSuite()
    defer { control.removePersistentDomain(forName: name) }
    let unavailable = try #require(UnavailableDefaults(suiteName: name))
    control.set("saved", forKey: "probe")

    unavailable.removePersistentDomain(forName: name)

    #expect(control.persistentDomain(forName: name) as? [String: String] == ["probe": "saved"])
  }

  @Test func typedAndKeyValueReadsHidePersistedValues() throws {
    let (name, control) = TestDefaults.makeNamedSuite()
    defer { control.removePersistentDomain(forName: name) }
    let unavailable = try #require(UnavailableDefaults(suiteName: name))
    control.setPersistentDomain(
      [
        "string": "saved", "array": ["saved"], "dictionary": ["saved": "value"],
        "data": Data([1]), "number": 42, "bool": true
      ],
      forName: name
    )
    control.set(URL(fileURLWithPath: "/saved"), forKey: "url")

    #expect(unavailable.string(forKey: "string") == nil)
    #expect(unavailable.array(forKey: "array") == nil)
    #expect(unavailable.stringArray(forKey: "array") == nil)
    #expect(unavailable.dictionary(forKey: "dictionary") == nil)
    #expect(unavailable.data(forKey: "data") == nil)
    #expect(unavailable.url(forKey: "url") == nil)
    #expect(unavailable.integer(forKey: "number") == 0)
    #expect(unavailable.float(forKey: "number") == 0)
    #expect(unavailable.double(forKey: "number") == 0)
    #expect(unavailable.bool(forKey: "bool") == false)
    #expect(unavailable.value(forKey: "string") == nil)
  }

  @Test func typedAndKeyValueWritesLeavePersistentDomainUnchanged() throws {
    let (name, control) = TestDefaults.makeNamedSuite()
    defer { control.removePersistentDomain(forName: name) }
    let unavailable = try #require(UnavailableDefaults(suiteName: name))
    control.set("saved", forKey: "probe")

    unavailable.set(42, forKey: "integer")
    unavailable.set(Float(42), forKey: "float")
    unavailable.set(Double(42), forKey: "double")
    unavailable.set(true, forKey: "bool")
    unavailable.set(URL(fileURLWithPath: "/leaked"), forKey: "url")
    unavailable.setValue("replaced", forKey: "probe")

    #expect(control.persistentDomain(forName: name) as? [String: String] == ["probe": "saved"])
  }

  @Test func volatileDomainsRemainEmptyAfterWrites() throws {
    let (name, _) = TestDefaults.makeNamedSuite()
    let unavailable = try #require(UnavailableDefaults(suiteName: name))

    unavailable.setVolatileDomain(["probe": "leaked"], forName: name)

    #expect(unavailable.volatileDomain(forName: name).isEmpty)
    #expect(unavailable.volatileDomainNames.isEmpty)
    #expect(unavailable.dictionaryRepresentation().isEmpty)
  }
}
