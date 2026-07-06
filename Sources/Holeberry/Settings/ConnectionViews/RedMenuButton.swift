import AppKit
import SwiftUI

/// A macOS button that shows an NSMenu with a red "Delete" item.
///
/// SwiftUI `Menu` and `Button(role: .destructive)` do not render red on macOS
/// because `NSMenuItem` has no destructive style. This bridges AppKit to use
/// `NSAttributedString` with `.systemRed` on the Delete item.
struct RedMenuButton: NSViewRepresentable {
  let editAction: () -> Void
  let deleteAction: () -> Void

  func makeNSView(context: Context) -> NSButton {
    let button = NSButton()
    button.title = "···"
    button.bezelStyle = .inline
    button.controlSize = .mini
    button.font = .systemFont(ofSize: 10, weight: .medium)
    button.toolTip = "More options"
    button.target = context.coordinator
    button.action = #selector(Coordinator.buttonClicked(_:))
    return button
  }

  func updateNSView(_ nsView: NSButton, context: Context) {
    context.coordinator.editAction = editAction
    context.coordinator.deleteAction = deleteAction
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(editAction: editAction, deleteAction: deleteAction)
  }

  final class Coordinator: NSObject {
    var editAction: () -> Void
    var deleteAction: () -> Void

    init(editAction: @escaping () -> Void, deleteAction: @escaping () -> Void) {
      self.editAction = editAction
      self.deleteAction = deleteAction
    }

    @objc func buttonClicked(_ sender: NSButton) {
      let menu = NSMenu()

      let editItem = NSMenuItem(
        title: "Edit",
        action: #selector(editTapped),
        keyEquivalent: ""
      )
      editItem.target = self
      editItem.image = NSImage(
        systemSymbolName: "pencil", accessibilityDescription: "Edit")

      let deleteItem = NSMenuItem(
        title: "Delete",
        action: #selector(deleteTapped),
        keyEquivalent: ""
      )
      deleteItem.target = self
      let redConfig = NSImage.SymbolConfiguration(hierarchicalColor: .systemRed)
      deleteItem.image = NSImage(
        systemSymbolName: "trash", accessibilityDescription: "Delete"
      )?.withSymbolConfiguration(redConfig)
      deleteItem.attributedTitle = NSAttributedString(
        string: "Delete",
        attributes: [.foregroundColor: NSColor.systemRed]
      )

      menu.items = [editItem, deleteItem]
      menu.popUp(
        positioning: nil,
        at: NSPoint(x: 0, y: sender.bounds.height),
        in: sender
      )
    }

    @objc func editTapped() { editAction() }
    @objc func deleteTapped() { deleteAction() }
  }
}
