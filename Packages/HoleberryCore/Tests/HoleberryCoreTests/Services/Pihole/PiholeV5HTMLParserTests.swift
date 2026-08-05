import Foundation
import Testing

@testable import HoleberryCore

@Suite("v5 HTML Parsing")
@MainActor
struct V5HTMLParsingTests {
  @Test func parseDomainsFromValidHTML() throws {
    let html = """
      <html><body><table>
      <tr><th>Domain</th><th>Action</th></tr>
      <tr><td>doubleclick.net</td><td>Delete</td></tr>
      <tr><td>tracker.example.com</td><td>Delete</td></tr>
      </table></body></html>
      """
    let parser = PiholeV5HTMLParser()
    let entries = parser.parseDomains(from: html, type: 0)
    #expect(entries.count == 2)
    #expect(entries[0].domain == "doubleclick.net")
    #expect(entries[0].type == 0)
    #expect(entries[1].domain == "tracker.example.com")
    #expect(entries[1].type == 0)
  }

  @Test func parseDomainsFromHTMLWithNestedTags() throws {
    let html = """
      <table>
      <tr><td><strong>ads.example.com</strong></td><td><a href="#">Delete</a></td></tr>
      <tr><td><span class="domain">spy.net</span></td><td><a href="#">Delete</a></td></tr>
      </table>
      """
    let parser = PiholeV5HTMLParser()
    let entries = parser.parseDomains(from: html, type: 0)
    #expect(entries.count == 2)
    #expect(entries[0].domain == "ads.example.com")
    #expect(entries[1].domain == "spy.net")
  }

  @Test func parseDomainsFromMalformedHTML() throws {
    let html = "<html><body><p>No table here</p></body></html>"
    let parser = PiholeV5HTMLParser()
    let entries = parser.parseDomains(from: html, type: 0)
    #expect(entries.isEmpty)
  }

  @Test func parseDomainsFromEmptyHTML() throws {
    let parser = PiholeV5HTMLParser()
    let entries = parser.parseDomains(from: "", type: 0)
    #expect(entries.isEmpty)
  }

  @Test func parseDomainsFiltersHeaderRow() throws {
    let html = """
      <table>
      <tr><td>Domain</td><td>Delete</td></tr>
      <tr><td>real-domain.com</td><td>Delete</td></tr>
      </table>
      """
    let parser = PiholeV5HTMLParser()
    let entries = parser.parseDomains(from: html, type: 1)
    #expect(entries.count == 1)
    #expect(entries[0].domain == "real-domain.com")
    #expect(entries[0].type == 1)
  }
}
