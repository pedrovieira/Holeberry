import Defaults
import HoleberryCore
import SwiftUI
import UniformTypeIdentifiers

/// Settings tab that lets the user configure the numeric unblock durations
/// shown in the "Disable Blocking ▸" and "Unblock <domain> ▸" menus.
///
/// The fake menu is two layers: a squared `NSVisualEffectView` stage that
/// spans the section edge to edge (vibrancy surface), with a rounded-corner
/// menu panel on top that uses the native menu material. Numeric rows are
/// draggable (hover-reveal handle) and deletable (hover-reveal ✕);
/// "Indefinitely" and "Custom…" are locked rows rendered below a separator.
struct DurationsSettingsView: View {
  @Default private var durations: [UnblockDurationEntry]

  @State private var draggedEntryID: UUID?
  @State private var hoveredEntryID: UUID?
  @State private var showResetConfirmation = false
  @State private var showDeleteConfirmation = false
  @State private var entryPendingDeletion: UnblockDurationEntry?

  init(defaultsSuite: UserDefaults = .standard) {
    _durations = .init(.unblockDurations(suite: defaultsSuite))
  }

  var body: some View {
    Section("Unblock Durations") {
      VStack(alignment: .leading, spacing: 10) {
        Text(
          "These durations appear in the Disable Blocking and Unblock menus. "
            + "Drag to reorder, hover to delete. Indefinitely and Custom… are always included."
        )
        .font(.callout)
        .foregroundColor(.secondary)
        .fixedSize(horizontal: false, vertical: true)

        fakeMenu

        reAddChipsRow

        HStack {
          Button("Reset to Defaults") {
            showResetConfirmation = true
          }
          .disabled(isAtDefaults)
          .confirmationDialog(
            "Restore default durations?",
            isPresented: $showResetConfirmation,
            titleVisibility: .visible
          ) {
            Button("Restore Defaults", role: .destructive) {
              resetToDefaults()
            }
            Button("Cancel", role: .cancel) {}
          } message: {
            Text("This removes your custom durations.")
          }
          Spacer()
          Button("Add Duration", action: addDuration)
            .buttonStyle(.borderedProminent)
            .disabled(durations.count >= UnblockDurationEntry.maxCount)
        }

        if durations.count >= UnblockDurationEntry.maxCount {
          Text("Limit of \(UnblockDurationEntry.maxCount) durations reached.")
            .font(.caption)
            .foregroundColor(.secondary)
        }
      }
      // Background drop target: clears the drag state whenever a drag ends
      // over the tab (rows clear it themselves via their own delegate).
      .onDrop(
        of: [.text],
        delegate: MenuStageDropDelegate {
          draggedEntryID = nil
        }
      )
      // Delete confirmation, presented with the entry that was clicked.
      .confirmationDialog(
        Text(deleteTitle),
        isPresented: $showDeleteConfirmation,
        titleVisibility: .visible,
        presenting: entryPendingDeletion
      ) { entry in
        Button("Delete", role: .destructive) {
          durations.removeAll { $0.id == entry.id }
        }
        Button("Cancel", role: .cancel) {
          entryPendingDeletion = nil
        }
      } message: { entry in
        Text("“\(UnblockDurationFormatter.string(from: entry.seconds))” will no longer appear in the menus.")
      }
    }
  }

  private var deleteTitle: String {
    guard let entryPendingDeletion else { return "" }
    return "Delete \(UnblockDurationFormatter.string(from: entryPendingDeletion.seconds))?"
  }

  /// True when the list is exactly the default entries (same values, same
  /// order, same stable ids) — Reset would be a no-op.
  private var isAtDefaults: Bool {
    durations == UnblockDurationEntry.defaultEntries
  }

  // MARK: - Actions

  private func addDuration() {
    guard durations.count < UnblockDurationEntry.maxCount else { return }
    let alert = DurationPickerAlert(
      title: "Add Duration",
      message: "Choose how long to unblock.",
      confirmButton: "Add",
      defaultDuration: 5 * 60
    )
    guard let seconds = alert.runDurationPicker() else { return }
    // Ignore values already covered by an existing entry — no duplicates.
    let isDuplicate = durations.contains { $0.seconds == seconds }
    guard !isDuplicate else { return }
    durations.append(UnblockDurationEntry(seconds: seconds))
  }

  private func resetToDefaults() {
    durations = UnblockDurationEntry.defaultEntries
  }

  // MARK: - Fake menu

  private var fakeMenu: some View {
    VStack(spacing: 0) {
      ForEach(durations) { entry in
        menuRow(entry)
      }
      if !durations.isEmpty {
        Divider()
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
      }
      lockedRow(title: "Indefinitely")
      lockedRow(title: "Custom…")
    }
    .padding(5)
    // The menu panel uses the native menu material so it adapts to the
    // system appearance, like a real macOS menu. The corner radius (12pt)
    // and hairline border match the look of Sonoma-era NSMenu panels.
    .background(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(.regularMaterial)
        .overlay(
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 14, y: 8)
    )
    .frame(maxWidth: 220)
    // Squared NSVisualEffectView stage, edge to edge behind the menu, with
    // a small corner radius and matching hairline border.
    // Vertical padding is taller than horizontal so the stage reads as a
    // generous backdrop around the menu panel.
    .padding(.horizontal, 14)
    .padding(.vertical, 34)
    .frame(maxWidth: .infinity)
    .background {
      VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
    }
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
    )
  }

  private func menuRow(_ entry: UnblockDurationEntry) -> some View {
    let isHovered = hoveredEntryID == entry.id
    let isDragging = draggedEntryID == entry.id
    return HStack(spacing: 6) {
      Image(systemName: "line.3.horizontal")
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .frame(width: 14)
        .opacity(isHovered ? 1 : 0)
      Text(UnblockDurationFormatter.string(from: entry.seconds))
        .font(.system(size: 13))
        .frame(maxWidth: .infinity, alignment: .leading)
      Button {
        entryPendingDeletion = entry
        showDeleteConfirmation = true
      } label: {
        Image(systemName: "xmark")
          .font(.system(size: 8, weight: .bold))
          .frame(width: 15, height: 15)
          .background(.quaternary, in: Circle())
      }
      .buttonStyle(.plain)
      .opacity(isHovered ? 1 : 0)
      .accessibilityLabel("Delete \(UnblockDurationFormatter.string(from: entry.seconds))")
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 5)
    .background(
      RoundedRectangle(cornerRadius: 5, style: .continuous)
        .fill(isHovered ? AnyShapeStyle(.tint.opacity(0.16)) : AnyShapeStyle(.clear))
    )
    .contentShape(Rectangle())
    .onHover { hovering in
      hoveredEntryID = hovering ? entry.id : nil
    }
    .opacity(isDragging ? 0.5 : 1)
    .onDrag {
      draggedEntryID = entry.id
      return NSItemProvider(object: entry.id.uuidString as NSString)
    }
    .onDrop(
      of: [.text],
      delegate: MenuRowDropDelegate(
        draggedID: draggedEntryID,
        targetID: entry.id,
        move: moveDuration
      ) {
        draggedEntryID = nil
      }
    )
  }

  private func lockedRow(title: String) -> some View {
    HStack(spacing: 6) {
      Color.clear.frame(width: 14)
      Text(title)
        .font(.system(size: 13))
        .frame(maxWidth: .infinity, alignment: .leading)
      Image(systemName: "lock.fill")
        .font(.system(size: 9))
        .foregroundStyle(.tertiary)
        .frame(width: 15, height: 15)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 5)
  }

  // MARK: - Re-add chips

  @ViewBuilder
  private var reAddChipsRow: some View {
    let missingDefaults = UnblockDurationEntry.defaultEntries.filter { defaultEntry in
      !durations.contains { $0.seconds == defaultEntry.seconds }
    }
    if !missingDefaults.isEmpty {
      HStack(spacing: 8) {
        Text("Re-add:")
          .font(.callout)
          .foregroundColor(.secondary)
        ForEach(missingDefaults) { defaultEntry in
          Button {
            guard durations.count < UnblockDurationEntry.maxCount else { return }
            durations.append(UnblockDurationEntry(seconds: defaultEntry.seconds))
          } label: {
            Text("+ \(UnblockDurationFormatter.string(from: defaultEntry.seconds))")
              .font(.caption.weight(.medium))
              .padding(.horizontal, 10)
              .padding(.vertical, 3)
              .overlay(
                Capsule().strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1, dash: [4]))
              )
          }
          .buttonStyle(.plain)
          .foregroundStyle(.tint)
        }
        Spacer()
      }
    }
  }

  // MARK: - Reordering

  private func moveDuration(from draggedID: UUID, to targetID: UUID) {
    guard
      let fromIdx = durations.firstIndex(where: { $0.id == draggedID }),
      let toIdx = durations.firstIndex(where: { $0.id == targetID }),
      fromIdx != toIdx
    else { return }
    durations.move(fromOffsets: IndexSet(integer: fromIdx), toOffset: toIdx > fromIdx ? toIdx + 1 : toIdx)
  }

  private struct MenuRowDropDelegate: DropDelegate {
    let draggedID: UUID?
    let targetID: UUID
    let move: @MainActor (UUID, UUID) -> Void
    let onDragEnd: @MainActor () -> Void

    func dropEntered(info: DropInfo) {
      guard let draggedID, draggedID != targetID else { return }
      move(draggedID, targetID)
    }

    func dropEnded(info: DropInfo) {
      onDragEnd()
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
      DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
      onDragEnd()
      return true
    }
  }

  /// Background drop target for the whole tab: clears the drag state when
  /// a drag ends anywhere over the tab that no row delegate covers.
  private struct MenuStageDropDelegate: DropDelegate {
    let onDragEnd: @MainActor () -> Void

    func dropEnded(info: DropInfo) {
      onDragEnd()
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
      // Propose a move (not the default copy) so the cursor doesn't show
      // the green "+" badge while dragging a row across the stage.
      DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
      onDragEnd()
      return true
    }
  }
}
