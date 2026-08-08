import Foundation
import Testing

@testable import HoleberryCore

@Suite("ServerCheckFailure classification")
struct ServerCheckFailureTests {
  @Test("invalid credentials are auth failures with passwordMayHaveChanged")
  func invalidCredentials() {
    #expect(ServerCheckFailure.classify(.invalidCredentials) == .auth(.passwordMayHaveChanged))
    #expect(ServerCheckFailure.classify(.reauthenticationFailed) == .auth(.passwordMayHaveChanged))
  }

  @Test("401 and unauthorized map to authenticationFailed")
  func unauthorized() {
    #expect(ServerCheckFailure.classify(.unauthorized) == .auth(.authenticationFailed))
    #expect(ServerCheckFailure.classify(.server(401, "bad token")) == .auth(.authenticationFailed))
  }

  @Test("auth-adjacent cases map to their own reasons")
  func authAdjacent() {
    #expect(ServerCheckFailure.classify(.totpRequired) == .auth(.totpRequired))
    #expect(ServerCheckFailure.classify(.rateLimited) == .auth(.rateLimited))
    #expect(ServerCheckFailure.classify(.sessionLimitReached) == .auth(.sessionLimitReached))
  }

  @Test("everything else is unreachable")
  func unreachable() {
    #expect(ServerCheckFailure.classify(.network("timeout")) == .unreachable)
    #expect(ServerCheckFailure.classify(.server(500, "boom")) == .unreachable)
    #expect(ServerCheckFailure.classify(.server(404, "nope")) == .unreachable)
    #expect(ServerCheckFailure.classify(.tlsUntrusted) == .unreachable)
    #expect(ServerCheckFailure.classify(.decoding("garbage")) == .unreachable)
    #expect(ServerCheckFailure.classify(.unknown("weird")) == .unreachable)
    #expect(ServerCheckFailure.classify(.duplicateDomain) == .unreachable)
  }
}

@Suite("ServerConnectionState")
struct ServerConnectionStateTests {
  @Test("unreachable carries lastSeen")
  func unreachableCarriesLastSeen() {
    let date = Date(timeIntervalSince1970: 1_000)
    #expect(ServerConnectionState.unreachable(lastSeen: date) == .unreachable(lastSeen: date))
  }
}
