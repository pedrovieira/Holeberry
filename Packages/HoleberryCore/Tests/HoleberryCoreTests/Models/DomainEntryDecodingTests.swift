import Foundation
import Testing

@testable import HoleberryCore

@Suite("DomainEntry decoding")
struct DomainEntryDecodingTests {
  @Test("decodes enabled as Bool (v6), Int (v5), and absent")
  func decodesEnabled() throws {
    let v6 = Data(#"{"id":1,"domain":"a.com","type":"allow","enabled":true}"#.utf8)
    #expect(try JSONDecoder().decode(DomainEntry.self, from: v6).enabled == true)

    let v5 = Data(#"{"id":1,"domain":"a.com","type":0,"enabled":0}"#.utf8)
    #expect(try JSONDecoder().decode(DomainEntry.self, from: v5).enabled == false)

    let missing = Data(#"{"domain":"a.com","type":0}"#.utf8)
    #expect(try JSONDecoder().decode(DomainEntry.self, from: missing).enabled == nil)
  }
}
