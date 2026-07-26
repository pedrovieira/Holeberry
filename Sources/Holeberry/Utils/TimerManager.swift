import Combine
import Foundation

final class TimerManager: ObservableObject {
  @Published var isRunning = false
  @Published var remainingSeconds: TimeInterval = 0
  @Published var totalDuration: TimeInterval?

  private var endTime: ContinuousClock.Instant?
  private var countdownTimer: AnyCancellable?

  var formattedTime: String {
    guard isRunning else { return "" }
    let totalSeconds = Int(ceil(max(0, remainingSeconds)))
    if totalSeconds >= 60 {
      return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    } else {
      return "\(totalSeconds)s"
    }
  }

  func start(duration: TimeInterval?) {
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

  func cancel() {
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
        guard let self else { return }
        guard let endTime = self.endTime else { return }
        let now = ContinuousClock.now
        if endTime > now {
          self.remainingSeconds = (endTime - now) / .seconds(1)
        } else {
          self.cancel()
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
