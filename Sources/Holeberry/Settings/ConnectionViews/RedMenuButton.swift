import AppKit
import SwiftUI

// MARK: - Shared Menu Builder

/// Builds the NSMenu used by both the button and the right-click overlay.
enum RedMenuBuilder {
  static func makeMenu(
    editAction: @escaping () -> Void,
    deleteAction: @escaping () -> Void,
    target: AnyObject,
    editSelector: Selector,
    deleteSelector: Selector
  ) -> NSMenu {
    let menu = NSMenu()

    let editItem = NSMenuItem(
      title: "Edit",
      action: editSelector,
      keyEquivalent: ""
    )
    editItem.target = target
    editItem.image = NSImage(
      systemSymbolName: "pencil", accessibilityDescription: "Edit")

    let deleteItem = NSMenuItem(
      title: "Delete",
      action: deleteSelector,
      keyEquivalent: ""
    )
    deleteItem.target = target
    let redConfig = NSImage.SymbolConfiguration(hierarchicalColor: .systemRed)
    deleteItem.image = NSImage(
      systemSymbolName: "trash", accessibilityDescription: "Delete"
    )?.withSymbolConfiguration(redConfig)
    deleteItem.attributedTitle = NSAttributedString(
      string: "Delete",
      attributes: [.foregroundColor: NSColor.systemRed]
    )

    menu.items = [editItem, .separator(), deleteItem]
    return menu
  }
}

// MARK: - "···" Button

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

  @MainActor
  final class Coordinator: NSObject {
    var editAction: () -> Void
    var deleteAction: () -> Void

    init(editAction: @escaping () -> Void, deleteAction: @escaping () -> Void) {
      self.editAction = editAction
      self.deleteAction = deleteAction
    }

    @objc func buttonClicked(_ sender: NSButton) {
      let menu = RedMenuBuilder.makeMenu(
        editAction: editAction,
        deleteAction: deleteAction,
        target: self,
        editSelector: #selector(editTapped),
        deleteSelector: #selector(deleteTapped)
      )
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

// MARK: - Right-Click Context Menu Overlay

/// A transparent overlay that shows the same red-menu on right-click.
/// Apply via `.overlay(RedContextMenu(...))` on the row.
struct RedContextMenu: NSViewRepresentable {
  let editAction: () -> Void
  let deleteAction: () -> Void

  func makeNSView(context: Context) -> ContextMenuOverlayView {
    let view = ContextMenuOverlayView()
    view.coordinator = context.coordinator
    return view
  }

  func updateNSView(_ nsView: ContextMenuOverlayView, context: Context) {
    context.coordinator.editAction = editAction
    context.coordinator.deleteAction = deleteAction
  }

  func makeCoordinator() -> ContextMenuCoordinator {
    ContextMenuCoordinator(editAction: editAction, deleteAction: deleteAction)
  }

  @MainActor
  final class ContextMenuCoordinator: NSObject {
    var editAction: () -> Void
    var deleteAction: () -> Void

    init(editAction: @escaping () -> Void, deleteAction: @escaping () -> Void) {
      self.editAction = editAction
      self.deleteAction = deleteAction
    }

    @objc func editTapped() { editAction() }
    @objc func deleteTapped() { deleteAction() }
  }
}

final class ContextMenuOverlayView: NSView {
  var coordinator: RedContextMenu.ContextMenuCoordinator?

  override func rightMouseDown(with event: NSEvent) {
    guard let coordinator else {
      super.rightMouseDown(with: event)
      return
    }
    let menu = RedMenuBuilder.makeMenu(
      editAction: coordinator.editAction,
      deleteAction: coordinator.deleteAction,
      target: coordinator,
      editSelector: #selector(RedContextMenu.ContextMenuCoordinator.editTapped),
      deleteSelector: #selector(RedContextMenu.ContextMenuCoordinator.deleteTapped)
    )
    let point = convert(event.locationInWindow, from: nil)
    menu.popUp(positioning: nil, at: point, in: self)
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    // Only intercept right-clicks; pass everything else through to SwiftUI.
    if NSApp.currentEvent?.type == .rightMouseDown {
      return self
    }
    return nil
  }
}
