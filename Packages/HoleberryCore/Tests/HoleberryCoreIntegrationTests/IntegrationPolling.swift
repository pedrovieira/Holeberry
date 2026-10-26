import Foundation

enum PollingError: Error, LocalizedError, Equatable {
  case invalidTiming
  case timedOut(String)

  var errorDescription: String? {
    switch self {
    case .invalidTiming:
      return "pollUntil requires a positive timeout and interval."
    case .timedOut(let description):
      return "Timed out while waiting for \(description)."
    }
  }
}

/// Polls an observation until it succeeds or the monotonic deadline passes.
///
/// Only observations belong here; never retry a mutation or a failed assertion.
@MainActor
func pollUntil(
  timeout: Duration = .seconds(20),
  interval: Duration = .milliseconds(250),
  description: String,
  condition: () async throws -> Bool
) async throws {
  guard timeout > .zero, interval > .zero else {
    throw PollingError.invalidTiming
  }

  let clock = ContinuousClock()
  let deadline = clock.now.advanced(by: timeout)

  while clock.now < deadline {
    if try await condition() {
      return
    }
    let remaining = deadline - clock.now
    try await Task.sleep(for: interval < remaining ? interval : remaining)
  }
  throw PollingError.timedOut(description)
}
