import AppKit

/// An `NSAlert` subclass that presents a `DurationField` as its accessory view
/// and returns the user-selected duration via `runDurationPicker()`.
///
/// Usage:
/// ```swift
/// let alert = DurationPickerAlert(
///     title: "Custom Unblock Duration",
///     message: "Choose how long to unblock \"example.com\".",
///     confirmButton: "Unblock",
///     defaultDuration: 5 * 60
/// )
/// guard let seconds = alert.runDurationPicker() else { return }
/// // use seconds…
/// ```
@MainActor
final class DurationPickerAlert: NSAlert {
  /// The duration the user selected, available after `runDurationPicker()` returns.
  private let durationField: DurationField

  // MARK: - Init

  init(
    title: String,
    message: String,
    confirmButton: String,
    defaultDuration: TimeInterval = 30 * 60
  ) {
    self.durationField = DurationField(initialDuration: defaultDuration)
    super.init()

    messageText = title
    informativeText = message
    addButton(withTitle: confirmButton)
    addButton(withTitle: "Cancel")

    accessoryView = durationField
    window.initialFirstResponder = durationField

    // Force synchronous layout before entering the modal run loop.
    durationField.layoutSubtreeIfNeeded()
  }

  // MARK: - Public API

  /// Presents the alert modally and returns the chosen duration in seconds,
  /// or `nil` if the user cancelled.
  func runDurationPicker() -> TimeInterval? {
    // Activate the app so the alert becomes the key window and receives
    // keyboard focus. Without this, a menu-bar app's modal alert can
    // appear without focus, requiring an extra click.
    NSApp.activate(ignoringOtherApps: true)

    let response = runModal()
    guard response == .alertFirstButtonReturn else { return nil }
    let secs = durationField.duration
    return secs > 0 ? secs : nil
  }
}
