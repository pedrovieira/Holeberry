import AppKit
import SwiftUI

/// An `NSTextField`-backed text field that hard-limits the visible text to
/// `maxLength` characters while the user is typing or pasting.
///
/// SwiftUI's `TextField` cannot enforce a live character limit on macOS:
/// truncating inside a custom binding's setter only shortens the *bound*
/// value — the AppKit-backed field keeps displaying everything the user typed
/// and only "snaps back" once it commits (focus loss / Return). This wrapper
/// instead truncates in `controlTextDidChange`, which updates the visible text
/// immediately, so the 21st character never appears.
struct LimitedTextField: NSViewRepresentable {
  @Binding var text: String
  var maxLength: Int
  var placeholder: String = ""
  var isEnabled: Bool = true
  var onCommit: (() -> Void)?

  func makeCoordinator() -> Coordinator {
    Coordinator(self)
  }

  func makeNSView(context: Context) -> NSTextField {
    let field = NSTextField()
    field.bezelStyle = .roundedBezel
    field.placeholderString = placeholder
    field.isEnabled = isEnabled
    field.stringValue = String(text.prefix(maxLength))
    field.setContentHuggingPriority(.defaultLow, for: .horizontal)
    field.delegate = context.coordinator
    return field
  }

  func updateNSView(_ nsView: NSTextField, context: Context) {
    context.coordinator.parent = self
    if nsView.placeholderString != placeholder {
      nsView.placeholderString = placeholder
    }
    if nsView.isEnabled != isEnabled {
      nsView.isEnabled = isEnabled
    }
    // Never push more than maxLength into the field, and never clobber text
    // while the user is editing — the delegate keeps the binding in sync.
    if nsView.currentEditor() == nil, nsView.stringValue != text {
      nsView.stringValue = String(text.prefix(maxLength))
    }
  }

  @MainActor
  final class Coordinator: NSObject, NSTextFieldDelegate {
    var parent: LimitedTextField

    init(_ parent: LimitedTextField) {
      self.parent = parent
    }

    func controlTextDidChange(_ obj: Notification) {
      guard let field = obj.object as? NSTextField else { return }
      if field.stringValue.count > parent.maxLength {
        field.stringValue = String(field.stringValue.prefix(parent.maxLength))
        field.currentEditor()?.selectedRange = NSRange(
          location: field.stringValue.count,
          length: 0
        )
      }
      parent.text = field.stringValue
    }

    func controlTextDidEndEditing(_ obj: Notification) {
      guard let field = obj.object as? NSTextField else { return }
      parent.text = field.stringValue
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
      // Return = commit (mirrors SwiftUI `.onSubmit`); don't end editing here.
      guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
      parent.onCommit?()
      return true
    }
  }
}
