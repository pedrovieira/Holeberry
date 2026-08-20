import AppKit

/// Strongly retains the `MenuActionTarget` so that weak `NSMenuItem.target`
/// references stay valid for the entire lifetime of the status-bar menu.
final class MainStatusBarMenu: NSMenu {
  private let actionTarget: MenuActionTarget

  init(actionTarget: MenuActionTarget) {
    self.actionTarget = actionTarget
    super.init(title: "")
  }

  required init(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
}

/// Bridges `NSMenuItem` target-action to the closure-based `MenuActions`.
/// This is the only type in the system that uses `@objc`.
@MainActor
final class MenuActionTarget: NSObject {
  private let actions: MenuActions

  /// Swappable for testing; defaults to a real `NSAlert`-based picker.
  var promptDuration: (String, String, String) -> TimeInterval?

  init(actions: MenuActions) {
    self.actions = actions
    self.promptDuration = Self.defaultPromptDuration
  }

  // MARK: - Settings / Updates

  @objc func openAppSettings(_ sender: Any?) { actions.openAppSettings() }
  @objc func checkForUpdates(_ sender: Any?) { actions.checkForUpdates() }

  // MARK: - Disable / Re-enable Blocking

  /// Reads the duration from `sender.representedObject` (nil = indefinitely).
  @objc func toggleDisableBlocking(_ sender: NSMenuItem) {
    let duration = sender.representedObject as? TimeInterval
    actions.disableBlocking(duration)
  }

  @objc func disableCustomDuration(_ sender: Any?) {
    guard
      let seconds = promptDuration(
        "Custom Disable Time",
        "Choose how long to disable blocking.",
        "Disable"
      )
    else { return }
    actions.disableBlocking(seconds)
  }

  @objc func reEnableBlocking(_ sender: Any?) { actions.reEnableBlocking() }

  @objc func triggerGravityUpdate(_ sender: Any?) { actions.triggerGravityUpdate() }

  // MARK: - Per-domain duration submenu actions

  @objc func disableURLDurationAction(_ sender: NSMenuItem) {
    guard let dict = sender.representedObject as? NSDictionary,
      let domain = dict["domain"] as? String,
      let duration = dict["duration"] as? TimeInterval
    else { return }
    actions.disableURL(domain, duration)
  }

  @objc func disableURLWithCustomTime(_ sender: NSMenuItem) {
    guard let domain = sender.representedObject as? String else { return }
    guard
      let seconds = promptDuration(
        "Custom Unblock Duration",
        "Choose how long to unblock \"\(domain)\".",
        "Unblock"
      )
    else { return }
    actions.disableURL(domain, seconds)
  }

  @objc func addToAllowlistAction(_ sender: NSMenuItem) {
    guard let domain = sender.representedObject as? String else { return }
    actions.addToAllowlist(domain)
  }

  // MARK: - Browser tab

  @objc func enableBrowserPermissionAction(_ sender: Any?) { actions.enableBrowserPermission() }
  @objc func openAutomationSettingsAction(_ sender: Any?) { actions.openAutomationSettings() }

  // MARK: - Duration-prompt default implementation

  private static func defaultPromptDuration(title: String, message: String, button: String) -> TimeInterval? {
    let alert = DurationPickerAlert(
      title: title,
      message: message,
      confirmButton: button,
      defaultDuration: 30 * 60  // 30 minutes
    )
    return alert.runDurationPicker()
  }
}
