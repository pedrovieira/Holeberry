import Foundation
import Testing

@testable import Holeberry

@Suite("ResolvedBrowserTab")
struct ResolvedBrowserTabTests {
  @Test("Equatable")
  func equatable() {
    #expect(ResolvedBrowserTab.disabled == ResolvedBrowserTab.disabled)
    #expect(ResolvedBrowserTab.noBrowser == ResolvedBrowserTab.noBrowser)
    #expect(ResolvedBrowserTab.noURL(.safari) == ResolvedBrowserTab.noURL(.safari))
    #expect(ResolvedBrowserTab.noURL(.safari) != ResolvedBrowserTab.noURL(.chrome))
    #expect(ResolvedBrowserTab.url(.safari, "a.com") == ResolvedBrowserTab.url(.safari, "a.com"))
    #expect(ResolvedBrowserTab.url(.safari, "a.com") != ResolvedBrowserTab.url(.safari, "b.com"))
  }

  @Test("browser accessor")
  func browserAccessor() {
    #expect(ResolvedBrowserTab.disabled.browser == nil)
    #expect(ResolvedBrowserTab.noBrowser.browser == nil)
    #expect(ResolvedBrowserTab.permissionNeeded(.firefox).browser == .firefox)
    #expect(ResolvedBrowserTab.permissionDenied(.chrome).browser == .chrome)
    #expect(ResolvedBrowserTab.noURL(.safari).browser == .safari)
    #expect(ResolvedBrowserTab.url(.arc, "test.com").browser == .arc)
  }
}
