import Foundation
import Testing

@testable import HoleberryCore

@Suite("PiholeError")
struct PiholeErrorTests {
  @Test func descriptions() {
    #expect(PiholeError.unauthorized.errorDescription == "Authentication failed. Check your credential.")
    #expect(PiholeError.network("timeout").errorDescription == "Network error: timeout")
    #expect(PiholeError.server(500, nil).errorDescription == "Server error (500)")
    #expect(
      PiholeError.server(500, "Internal Server Error").errorDescription
        == "Server error (500): Internal Server Error")
    #expect(PiholeError.tlsUntrusted.errorDescription == "Untrusted TLS certificate")
    #expect(PiholeError.duplicateDomain.errorDescription == "Domain is already in the list")
    #expect(PiholeError.decoding("bad JSON").errorDescription == "Failed to parse response: bad JSON")
    #expect(PiholeError.totpRequired.errorDescription == "TOTP code required for 2FA")
    #expect(PiholeError.unknown("something broke").errorDescription == "Unexpected error: something broke")
    #expect(PiholeError.invalidCredentials.errorDescription == "Invalid Pi-hole password or application password.")
    #expect(PiholeError.rateLimited.errorDescription == "Login rate limited. Please wait before trying again.")
    #expect(
      PiholeError.reauthenticationFailed.errorDescription
        == "Session re-authentication failed. The Pi-hole may be unreachable or the password was changed."
    )
    #expect(
      PiholeError.sessionLimitReached.errorDescription
        == "Pi-hole session limit reached. Sign out from other clients."
    )
  }

  @Test func equality() {
    #expect(PiholeError.unauthorized == PiholeError.unauthorized)
    #expect(PiholeError.unauthorized != PiholeError.totpRequired)
    #expect(PiholeError.duplicateDomain == PiholeError.duplicateDomain)
    #expect(PiholeError.network("x") == PiholeError.network("x"))
    #expect(PiholeError.network("x") != PiholeError.network("y"))
  }
}
