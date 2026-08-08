import AppKit
import SwiftUI

// MARK: - Shared Menu Builder

/// Builds the NSMenu used by both the button and the right-click overlay.
/// Gains state-aware recovery items: "Re-authenticate…" for auth errors,
/// "Retry connection" / "Edit connection…" for unreachable.
enum RedMenuBuilder {
  static func makeMenu(
    editAction: @escaping () -> Void,
    deleteAction: @escaping () -> Void,
    reauthenticateAction: @escaping () -> Void,
    retryAction: @escaping () -> Void,
    state: ServerConnectionState?,
    target: AnyObject,
    editSelector: Selector,
    deleteSelector: Selector,
    reauthenticateSelector: Selector,
    retrySelector: Selector
  ) -> NSMenu {
    let menu = NSMenu()

    if case .authError = state {
      let reauthItem = NSMenuItem(
        title: "Re-authenticate…",
        action: reauthenticateSelector,
        keyEquivalent: ""
      )
      reauthItem.target = target
      reauthItem.image = NSImage(
        systemSymbolName: "lock.fill", accessibilityDescription: "Re-authenticate")
      menu.addItem(reauthItem)
    }

    if case .unreachable = state {
      let retryItem = NSMenuItem(
        title: "Retry connection",
        action: retrySelector,
        keyEquivalent: ""
      )
      retryItem.target = target
      retryItem.image = NSImage(
        systemSymbolName: "arrow.clockwise", accessibilityDescription: "Retry connection")
      menu.addItem(retryItem)

      let editConnectionItem = NSMenuItem(
        title: "Edit connection…",
        action: editSelector,
        keyEquivalent: ""
      )
      editConnectionItem.target = target
      menu.addItem(editConnectionItem)
    }

    let editItem = NSMenuItem(
      title: "Edit",
      action: editSelector,
      keyEquivalent: ""
    )
    editItem.target = target
    editItem.image = NSImage(
      systemSymbolName: "pencil", accessibilityDescription: "Edit")
    menu.addItem(editItem)

    menu.addItem(.separator())

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

    menu.addItem(deleteItem)
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
  let reauthenticateAction: () -> Void
  let retryAction: () -> Void
  let state: ServerConnectionState?

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
    context.coordinator.reauthenticateAction = reauthenticateAction
    context.coordinator.retryAction = retryAction
    context.coordinator.state = state
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(
      editAction: editAction,
      deleteAction: deleteAction,
      reauthenticateAction: reauthenticateAction,
      retryAction: retryAction,
      state: state
    )
  }

  @MainActor
  final class Coordinator: NSObject {
    var editAction: () -> Void
    var deleteAction: () -> Void
    var reauthenticateAction: () -> Void
    var retryAction: () -> Void
    var state: ServerConnectionState?

    init(
      editAction: @escaping () -> Void,
      deleteAction: @escaping () -> Void,
      reauthenticateAction: @escaping () -> Void,
      retryAction: @escaping () -> Void,
      state: ServerConnectionState?
    ) {
      self.editAction = editAction
      self.deleteAction = deleteAction
      self.reauthenticateAction = reauthenticateAction
      self.retryAction = retryAction
      self.state = state
    }

    @objc func buttonClicked(_ sender: NSButton) {
      let menu = RedMenuBuilder.makeMenu(
        editAction: editAction,
        deleteAction: deleteAction,
        reauthenticateAction: reauthenticateAction,
        retryAction: retryAction,
        state: state,
        target: self,
        editSelector: #selector(editTapped),
        deleteSelector: #selector(deleteTapped),
        reauthenticateSelector: #selector(reauthenticateTapped),
        retrySelector: #selector(retryTapped)
      )
      menu.popUp(
        positioning: nil,
        at: NSPoint(x: 0, y: sender.bounds.height),
        in: sender
      )
    }

    @objc func editTapped() { editAction() }
    @objc func deleteTapped() { deleteAction() }
    @objc func reauthenticateTapped() { reauthenticateAction() }
    @objc func retryTapped() { retryAction() }
  }
}

// MARK: - Right-Click Context Menu Overlay

/// A transparent overlay that shows the same red-menu on right-click.
/// Apply via `.overlay(RedContextMenu(...))` on the row.
struct RedContextMenu: NSViewRepresentable {
  let editAction: () -> Void
  let deleteAction: () -> Void
  let reauthenticateAction: () -> Void
  let retryAction: () -> Void
  let state: ServerConnectionState?

  func makeNSView(context: Context) -> ContextMenuOverlayView {
    let view = ContextMenuOverlayView()
    view.coordinator = context.coordinator
    return view
  }

  func updateNSView(_ nsView: ContextMenuOverlayView, context: Context) {
    context.coordinator.editAction = editAction
    context.coordinator.deleteAction = deleteAction
    context.coordinator.reauthenticateAction = reauthenticateAction
    context.coordinator.retryAction = retryAction
    context.coordinator.state = state
  }

  func makeCoordinator() -> ContextMenuCoordinator {
    ContextMenuCoordinator(
      editAction: editAction,
      deleteAction: deleteAction,
      reauthenticateAction: reauthenticateAction,
      retryAction: retryAction,
      state: state
    )
  }

  @MainActor
  final class ContextMenuCoordinator: NSObject {
    var editAction: () -> Void
    var deleteAction: () -> Void
    var reauthenticateAction: () -> Void
    var retryAction: () -> Void
    var state: ServerConnectionState?

    init(
      editAction: @escaping () -> Void,
      deleteAction: @escaping () -> Void,
      reauthenticateAction: @escaping () -> Void,
      retryAction: @escaping () -> Void,
      state: ServerConnectionState?
    ) {
      self.editAction = editAction
      self.deleteAction = deleteAction
      self.reauthenticateAction = reauthenticateAction
      self.retryAction = retryAction
      self.state = state
    }

    @objc func editTapped() { editAction() }
    @objc func deleteTapped() { deleteAction() }
    @objc func reauthenticateTapped() { reauthenticateAction() }
    @objc func retryTapped() { retryAction() }
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
      reauthenticateAction: coordinator.reauthenticateAction,
      retryAction: coordinator.retryAction,
      state: coordinator.state,
      target: coordinator,
      editSelector: #selector(RedContextMenu.ContextMenuCoordinator.editTapped),
      deleteSelector: #selector(RedContextMenu.ContextMenuCoordinator.deleteTapped),
      reauthenticateSelector: #selector(RedContextMenu.ContextMenuCoordinator.reauthenticateTapped),
      retrySelector: #selector(RedContextMenu.ContextMenuCoordinator.retryTapped)
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
