import HoleberryCore
import Testing

@Suite("String extensions")
@MainActor
struct StringExtensionsTests {
  @Test(
    "Extracts the hostname without credentials, port, path, query, or fragment",
    arguments: [
      ("http://pihole.local", "pihole.local"),
      ("https://pihole.example:8443/admin?view=stats#queries", "pihole.example"),
      ("https://user:password@pihole.example/admin", "pihole.example"),
      ("http://192.168.1.20:8080/admin", "192.168.1.20"),
      ("http://[2001:db8::1]:8080/admin", "[2001:db8::1]"),
      ("https://PiHole.Example/admin", "PiHole.Example"),
      ("ftp://pihole.example/file", "pihole.example")
    ]
  )
  func extractsHostname(input: String, expected: String) {
    #expect(input.hostname == expected)
  }

  @Test(
    "Returns nil for empty, malformed, relative, or hostless URLs",
    arguments: [
      "", " ", "not a url", "pihole.local/admin", "/admin",
      "http://", "http:///admin", "http://[invalid", "file:///tmp/test", "about:blank"
    ]
  )
  func missingHostname(input: String) {
    #expect(input.hostname == nil)
  }
}
