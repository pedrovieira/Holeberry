import Combine
import Foundation

final class TimerManager: ObservableObject {
  @Published var isDisabled = false
  @Published var remainingSeconds: TimeInterval = 0
  @Published var totalDuration: TimeInterval?

  private var endTime: ContinuousClock.Instant?
  private var countdownTimer: AnyCancellable?

  var formattedTime: String {
    guard isDisabled else { return "" }
    let totalSeconds = Int(max(0, remainingSeconds))
    if totalSeconds >= 60 {
      return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    } else {
      return "\(totalSeconds)s"
    }
  }

  func startDisable(duration: TimeInterval?) {
    isDisabled = true
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

  func cancelDisable() {
    isDisabled = false
    remainingSeconds = 0
    totalDuration = nil
    endTime = nil
    stopCountdown()
  }

  func syncFromRemote(_ blockingStatus: BlockingStatus) {
    switch blockingStatus {
    case .enabled:
      cancelDisable()
    case .disabled(let remaining):
      if let remaining, remaining > 0 {
        isDisabled = true
        totalDuration = remaining
        self.remainingSeconds = remaining
        endTime = ContinuousClock.now + .seconds(remaining)
        startCountdown()
      } else {
        startDisable(duration: nil)
      }
    }
  }

  private func startCountdown() {
    stopCountdown()
    countdownTimer = Timer.publish(every: 1, on: .main, in: .common)
      .autoconnect()
      .sink { [weak self] _ in
        guard let self else { return }
        guard let endTime = self.endTime else { return }
        let now = ContinuousClock.now
        if endTime > now {
          self.remainingSeconds = (endTime - now) / .seconds(1)
        } else {
          self.cancelDisable()
        }
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
