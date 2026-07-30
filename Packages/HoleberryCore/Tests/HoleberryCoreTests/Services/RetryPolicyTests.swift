import Testing

@testable import HoleberryCore

/// A test error that is not related to network/server issues.
private struct NonRetryableError: Error, Equatable {}

/// A test error that simulates a network error.
private let testNetworkError = PiholeError.network("connection lost")

/// A test error that simulates a server error.
private let testServerError = PiholeError.server(500, "Internal Error")

/// A never-failing sleep that completes instantly — injectable for deterministic tests.
private let noSleep: @Sendable (Duration) async throws -> Void = { _ in }

/// Policy that retries everything — used to test retry mechanics.
private let retryAll = RetryPolicy(
  maxAttempts: 3,
  backoff: { _ in .seconds(0) },
  shouldRetry: { _ in true }
)

/// Policy that never retries — used to test non-retryable error passthrough.
private let retryNone = RetryPolicy(
  maxAttempts: 3,
  backoff: { _ in .seconds(0) },
  shouldRetry: { _ in false }
)

/// Sendable box for call-count tracking in @Sendable closures.
private final class CallCount: @unchecked Sendable {
  var value = 0
}

/// Sendable box for collecting durations across retry attempts.
private final class CapturedDurations: @unchecked Sendable {
  var values: [Duration] = []
}

@Suite("RetryPolicy + withRetry")
struct RetryPolicyTests {
  // MARK: - Default destructive policy

  @Test("destructive policy retries network errors")
  func destructiveRetriesNetworkError() async throws {
    let callCount = CallCount()
    try await withRetry(.destructive, sleep: noSleep) {
      callCount.value += 1
      if callCount.value < 2 { throw testNetworkError }
      return "done"
    }
    #expect(callCount.value == 2)
  }

  @Test("destructive policy retries 5xx server errors")
  func destructiveRetriesServerError() async throws {
    let callCount = CallCount()
    try await withRetry(.destructive, sleep: noSleep) {
      callCount.value += 1
      if callCount.value < 2 { throw testServerError }
      return "done"
    }
    #expect(callCount.value == 2)
  }

  @Test("destructive policy does not retry non-retryable errors")
  func destructiveNoRetryOnNonRetryable() async throws {
    let callCount = CallCount()
    await #expect(throws: NonRetryableError()) {
      try await withRetry(.destructive, sleep: noSleep) {
        callCount.value += 1
        throw NonRetryableError()
      }
    }
    #expect(callCount.value == 1)
  }

  @Test("destructive policy does not retry 4xx errors")
  func destructiveNoRetryOn4xx() async throws {
    let clientError = PiholeError.server(404, "Not Found")
    let callCount = CallCount()
    await #expect(throws: PiholeError.server(404, "Not Found")) {
      try await withRetry(.destructive, sleep: noSleep) {
        callCount.value += 1
        throw clientError
      }
    }
    #expect(callCount.value == 1)
  }

  @Test("destructive policy does not retry decoding errors")
  func destructiveNoRetryOnDecoding() async throws {
    let decodingError = PiholeError.decoding("bad json")
    let callCount = CallCount()
    await #expect(throws: PiholeError.decoding("bad json")) {
      try await withRetry(.destructive, sleep: noSleep) {
        callCount.value += 1
        throw decodingError
      }
    }
    #expect(callCount.value == 1)
  }

  // MARK: - Custom policy (retry all)

  @Test("succeeds on first attempt")
  func firstAttemptSucceeds() async throws {
    let callCount = CallCount()
    let result = try await withRetry(retryAll, sleep: noSleep) {
      callCount.value += 1
      return "done"
    }
    #expect(result == "done")
    #expect(callCount.value == 1)
  }

  @Test("retries and eventually succeeds")
  func retryThenSucceeds() async throws {
    let callCount = CallCount()
    try await withRetry(retryAll, sleep: noSleep) {
      callCount.value += 1
      if callCount.value < 3 { throw testNetworkError }
    }
    #expect(callCount.value == 3)
  }

  @Test("throws after exhausting all attempts")
  func exhaustsRetries() async throws {
    let callCount = CallCount()
    await #expect(throws: testNetworkError) {
      try await withRetry(retryAll, sleep: noSleep) {
        callCount.value += 1
        throw testNetworkError
      }
    }
    #expect(callCount.value == 3)
  }

  @Test("does not retry when shouldRetry returns false")
  func nonRetryablePassthrough() async throws {
    let callCount = CallCount()
    await #expect(throws: testNetworkError) {
      try await withRetry(retryNone, sleep: noSleep) {
        callCount.value += 1
        throw testNetworkError
      }
    }
    #expect(callCount.value == 1)
  }

  @Test("single-attempt policy never retries")
  func singleAttempt() async throws {
    let callCount = CallCount()
    let singleAttemptPolicy = RetryPolicy(
      maxAttempts: 1,
      backoff: { _ in .seconds(0) },
      shouldRetry: { _ in true }
    )
    await #expect(throws: testNetworkError) {
      try await withRetry(singleAttemptPolicy, sleep: noSleep) {
        callCount.value += 1
        throw testNetworkError
      }
    }
    #expect(callCount.value == 1)
  }

  // MARK: - Backoff computation

  @Test("backoff uses attempt index for duration")
  func backoffUsesAttemptIndex() async throws {
    let captured = CapturedDurations()
    let capturingSleep: @Sendable (Duration) async throws -> Void = { duration in
      captured.values.append(duration)
    }
    let customPolicy = RetryPolicy(
      maxAttempts: 3,
      backoff: { .seconds(Double($0 + 1) * 2) },  // 2s, 4s
      shouldRetry: { _ in true }
    )
    try? await withRetry(customPolicy, sleep: capturingSleep) {
      throw testNetworkError
    }
    #expect(captured.values.count == 2)
    #expect(captured.values[0] == .seconds(2))
    #expect(captured.values[1] == .seconds(4))
  }
}
