import Combine
import Foundation

public final class TimerManager: ObservableObject {
  public init() {}

  @Published public var isRunning = false
  @Published public var remainingSeconds: TimeInterval = 0
  @Published public var totalDuration: TimeInterval?

  /// Fires once when a time-boxed countdown expires naturally (not on `cancel()`).
  public var onEnded: (() -> Void)?

  private var endTime: ContinuousClock.Instant?
  private var countdownTimer: AnyCancellable?

  public var formattedTime: String {
    guard isRunning else { return "" }
    let totalSeconds = Int(ceil(max(0, remainingSeconds)))
    if totalSeconds >= 60 {
      return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    } else {
      return "\(totalSeconds)s"
    }
  }

  public func start(duration: TimeInterval?) {
    isRunning = true
    totalDuration = duration
    stopCountdown()
    if let duration {
      endTime = ContinuousClock.now + .seconds(duration)
      remainingSeconds = duration
      startCountdown()
    } else {
      endTime = nil
      remainingSeconds = 0
    }
  }

  public func cancel() {
    isRunning = false
    remainingSeconds = 0
    totalDuration = nil
    endTime = nil
    stopCountdown()
  }

  private func startCountdown() {
    stopCountdown()
    countdownTimer = Timer.publish(every: 1, on: .main, in: .common)
      .autoconnect()
      .sink { [weak self] _ in
        self?.countdownTick()
      }
  }

  /// Advances the countdown one tick; fires `onEnded` on expiry. Internal so
  /// tests can trigger expiry without real time.
  internal func countdownTick() {
    guard let endTime else { return }
    let now = ContinuousClock.now
    if endTime > now {
      remainingSeconds = (endTime - now) / .seconds(1)
    } else {
      cancel()
      onEnded?()
    }
  }

  private func stopCountdown() {
    countdownTimer?.cancel()
    countdownTimer = nil
  }

  deinit {
    stopCountdown()
  }
}
