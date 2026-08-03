import Foundation

/// Policy for retrying an operation with backoff.
public struct RetryPolicy: Sendable {
  /// Maximum number of attempts (including the first).
  let maxAttempts: Int
  /// Backoff duration for the given attempt index (0-based).
  let backoff: @Sendable (Int) -> Duration
  /// Whether the error should trigger a retry.
  let shouldRetry: @Sendable (any Error) -> Bool

  public init(
    maxAttempts: Int,
    backoff: @escaping @Sendable (Int) -> Duration,
    shouldRetry: @escaping @Sendable (any Error) -> Bool
  ) {
    self.maxAttempts = maxAttempts
    self.backoff = backoff
    self.shouldRetry = shouldRetry
  }
}

extension RetryPolicy {
  /// Default policy for destructive (mutation) API calls: 3 attempts,
  /// exponential backoff (1s, 2s, 4s), retry on network errors and 5xx.
  public static let destructive = RetryPolicy(
    maxAttempts: 3,
    backoff: { .seconds(pow(2.0, Double($0))) },
    shouldRetry: { error in
      guard let piholeError = error as? PiholeError else { return false }
      switch piholeError {
      case .network:
        return true
      case .server(let code, _):
        return (500...599).contains(code)
      default:
        return false
      }
    }
  )
}

/// Execute an operation with retry according to the given policy.
/// - Parameters:
///   - policy: The retry policy to follow.
///   - sleep: The sleep function (injectable for testing). Defaults to `Task.sleep`.
///   - operation: The throwing async operation to retry.
/// - Returns: The operation's result on success.
/// - Throws: The last error if all attempts fail or the error is not retryable.
public func withRetry<T: Sendable>(
  _ policy: RetryPolicy,
  sleep: @Sendable @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
  operation: @Sendable () async throws -> T
) async throws -> T {
  for attempt in 0..<policy.maxAttempts {
    do {
      return try await operation()
    } catch {
      guard policy.shouldRetry(error), attempt < policy.maxAttempts - 1 else {
        throw error
      }
      try await sleep(policy.backoff(attempt))
    }
  }
  // Unreachable given the loop + guard above, but compiler needs a path.
  throw PiholeError.unknown("RetryPolicy exhausted with empty attempt range")
}
