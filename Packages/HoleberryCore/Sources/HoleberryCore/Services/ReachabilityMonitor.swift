@preconcurrency import Combine
import Foundation
import Network

/// Monitors network reachability using NWPathMonitor. Publishes `isConnected` for reactive UI updates.
public final class ReachabilityMonitor: ObservableObject {
  @Published public var isConnected = true

  private let monitor = NWPathMonitor()
  private let queue = DispatchQueue(label: "me.pedrovieira.holeberry.reachability", qos: .background)
  private var cancellables = Set<AnyCancellable>()

  public var onConnect: (() -> Void)?

  public init() {
    let pathSubject = PassthroughSubject<Bool, Never>()

    monitor.pathUpdateHandler = { path in
      pathSubject.send(path.status == .satisfied)
    }
    monitor.start(queue: DispatchQueue.global(qos: .background))

    pathSubject
      .receive(on: DispatchQueue.main)
      .sink { [weak self] connected in
        let wasDisconnected = !(self?.isConnected ?? true)
        self?.isConnected = connected
        if connected && wasDisconnected {
          self?.onConnect?()
        }
      }
      .store(in: &cancellables)
  }

  deinit {
    monitor.cancel()
  }

  public func stop() {
    monitor.cancel()
  }
}
