import Foundation

/// Monotonic, finite observation polling for integration scenarios.
///
/// Polls observations only. It never retries a mutation or an assertion, and it
/// rejects a condition that reports success after its elapsed deadline.
enum IntegrationPollingError: Error, LocalizedError, Equatable {
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

@MainActor
func pollUntil(
  timeout: Duration = .seconds(15),
  interval: Duration = .milliseconds(250),
  description: String,
  condition: () async throws -> Bool
) async throws {
  guard timeout > .zero, interval > .zero else {
    throw IntegrationPollingError.invalidTiming
  }

  let clock = ContinuousClock()
  let deadline = clock.now.advanced(by: timeout)

  while true {
    try Task.checkCancellation()
    let satisfied = try await condition()
    let now = clock.now

    if satisfied {
      guard now <= deadline else {
        throw IntegrationPollingError.timedOut(description)
      }
      return
    }

    guard now < deadline else {
      throw IntegrationPollingError.timedOut(description)
    }

    let remaining = deadline - now
    try await clock.sleep(for: interval < remaining ? interval : remaining)
  }
}
