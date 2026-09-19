import Foundation
import Testing
@testable import HoleberryCore

@Suite("URL domain")
struct URLDomainTests {
  @Test("extracts host from http URL")
  func extractsHostFromHTTP() {
    #expect(URL(string: "http://www.example.com/page")?.domain == "www.example.com")
  }

  @Test("extracts host from https URL, ignoring path and query")
  func extractsHostFromHTTPS() {
    #expect(URL(string: "https://google.com/search?q=test")?.domain == "google.com")
  }

  @Test("returns nil for a relative URL")
  func relativeURLReturnsNil() {
    #expect(URL(string: "example.com/path")?.domain == nil)
  }

  @Test("returns nil for internal browser pages")
  func internalPagesReturnNil() {
    for page in [
      "about:blank", "chrome://settings", "chrome-extension://abc123",
      "edge://flags", "brave://bookmarks", "opera://history",
      "vivaldi://notes", "moz-extension://xyz"
    ] {
      #expect(URL(string: page)?.domain == nil, "\(page) should return nil")
    }
  }

  @Test("returns nil for non-web schemes")
  func nonWebSchemeReturnsNil() {
    #expect(URL(string: "ftp://example.com/file")?.domain == nil)
  }

  @Test("returns nil when an http URL has no host")
  func hostlessHTTPURLReturnsNil() {
    #expect(URL(string: "http://")?.domain == nil)
  }
}
