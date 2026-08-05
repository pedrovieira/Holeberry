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
///
/// Set `validate` to reject a duration while the alert is still open: the
/// alert wiggles and stays up (used to reject duplicates).
@MainActor
final class DurationPickerAlert: NSAlert {
  /// Called with the chosen duration when the user confirms. Return `false`
  /// to reject the value — the alert wiggles and stays open.
  var validate: ((TimeInterval) -> Bool)?

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

    // Route the confirm button (and the field's Return key) through
    // `confirmPressed` so `validate` can reject values before dismissal.
    if let confirmButton = buttons.first {
      confirmButton.target = self
      confirmButton.action = #selector(confirmPressed)
    }
    durationField.onConfirm = { [weak self] in
      self?.confirmPressed()
    }

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

  // MARK: - Confirmation

  @objc private func confirmPressed() {
    let seconds = durationField.duration
    if let validate, !validate(seconds) {
      wiggleWindow()
      return
    }
    NSApp.stopModal(withCode: .alertFirstButtonReturn)
  }

  // MARK: - Wiggle

  /// Animates the alert window horizontally, the classic "rejected input"
  /// shake, without dismissing the alert.
  private func wiggleWindow() {
    let alertWindow = window
    let origin = alertWindow.frame.origin
    let distance: CGFloat = 10

    NSAnimationContext.runAnimationGroup(
      { context in
        context.duration = 0.05
        alertWindow.animator().setFrameOrigin(NSPoint(x: origin.x - distance, y: origin.y))
      },
      completionHandler: {
        NSAnimationContext.runAnimationGroup(
          { context in
            context.duration = 0.1
            alertWindow.animator().setFrameOrigin(NSPoint(x: origin.x + distance, y: origin.y))
          },
          completionHandler: {
            NSAnimationContext.runAnimationGroup { context in
              context.duration = 0.05
              alertWindow.animator().setFrameOrigin(origin)
            }
          })
      })
  }
}
