import AppKit
import Combine
import OSLog

@MainActor
final class MenuBarController: NSObject {
  private let statusItem: NSStatusItem
  private let timerManager = TimerManager()
  private let serverManager = PiholeServerManager()
  private lazy var menuBuilder = MenuBuilder(
    serverManager: serverManager, timerManager: timerManager
  )
  private var cancellables = Set<AnyCancellable>()
  private let logger = Logger(subsystem: Logger.appSubsystem, category: "menu-bar")

  override init() {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    super.init()
    configureStatusItem()
    observeTimer()
    pollInitialStatus()
    listenForSettingsChanges()
  }

  private func configureStatusItem() {
    guard let button = statusItem.button else { return }
    button.image = NSImage(systemSymbolName: "shield.fill", accessibilityDescription: "Pi-hole Active")
    button.action = #selector(handleClick)
    button.target = self
  }

  @objc private func handleClick() {
    statusItem.menu = menuBuilder.buildMenu()
    statusItem.button?.performClick(nil)
    statusItem.menu = nil
  }

  private func observeTimer() {
    timerManager.$isDisabled
      .combineLatest(timerManager.$remainingSeconds)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] isDisabled, remaining in
        self?.updateDisplay(isDisabled: isDisabled, remaining: remaining)
      }
      .store(in: &cancellables)
  }

  private func updateDisplay(isDisabled: Bool, remaining: TimeInterval) {
    guard let button = statusItem.button else { return }
    if isDisabled && remaining > 0 {
      button.title = timerManager.formattedTime
      button.image = NSImage(
        systemSymbolName: "shield.slash.fill", accessibilityDescription: "Pi-hole Disabled"
      )
    } else if isDisabled {
      button.title = "∞"
      button.image = NSImage(
        systemSymbolName: "shield.slash.fill", accessibilityDescription: "Pi-hole Disabled Indefinitely"
      )
    } else {
      button.title = ""
      button.image = NSImage(systemSymbolName: "shield.fill", accessibilityDescription: "Pi-hole Active")
    }
  }

  private func pollInitialStatus() {
    guard let server = serverManager.servers.first, server.version != nil else { return }
    Task {
      do {
        let status = try await serverManager.getBlockingStatus(for: server)
        timerManager.syncFromRemote(status)
      } catch {
        logger.warning("Initial status poll failed: \(error.localizedDescription, privacy: .public)")
      }
    }
  }

  private func listenForSettingsChanges() {
    NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in
        self?.serverManager.reloadServers()
      }
      .store(in: &cancellables)
  }
}
