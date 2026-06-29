import Combine
import Foundation
import Network

/// Monitors network reachability using NWPathMonitor. Publishes `isConnected` for reactive UI updates.
final class ReachabilityMonitor: ObservableObject {
  @Published var isConnected = true

  private let monitor = NWPathMonitor()
  private let queue = DispatchQueue(label: "me.pedrovieira.holeberry.reachability", qos: .background)

  var onConnect: (() -> Void)?

  init() {
    monitor.pathUpdateHandler = { [weak self] path in
      let connected = path.status == .satisfied
      DispatchQueue.main.async {
        let wasDisconnected = !(self?.isConnected ?? true)
        self?.isConnected = connected
        if connected && wasDisconnected {
          self?.onConnect?()
        }
      }
    }
    monitor.start(queue: queue)
  }

  deinit {
    monitor.cancel()
  }

  func stop() {
    monitor.cancel()
  }
}
