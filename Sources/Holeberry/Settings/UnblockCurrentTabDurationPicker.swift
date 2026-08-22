import HoleberryCore
import SwiftUI

/// The "Duration" sub-row of the "Unblock Current Tab" shortcut in the
/// Shortcuts tab: a picker over the configured durations plus "Indefinite"
/// and "Custom...".
///
/// Repairs a dangling `.entry` selection (its duration was deleted in the
/// Durations tab) to `.indefinite`, so the picker always displays the value
/// the shortcut will actually use. "Indefinite" is a fixed option that always
/// exists, so the picker never has an empty or unset state.
struct UnblockCurrentTabDurationPicker: View {
  @Binding var durations: [UnblockDurationEntry]
  @Binding var selection: UnblockCurrentTabDurationSelection

  var body: some View {
    LabeledContent {
      Picker("", selection: $selection) {
        ForEach(durations) { entry in
          Text(UnblockDurationFormatter.string(from: entry.seconds))
            .tag(UnblockCurrentTabDurationSelection.entry(entry.id))
        }
        Text("Indefinite")
          .tag(UnblockCurrentTabDurationSelection.indefinite)
        Text("Custom...")
          .tag(UnblockCurrentTabDurationSelection.custom)
      }
      .labelsHidden()
      .pickerStyle(.menu)
    } label: {
      Text("Duration")
        .font(.callout)
        .foregroundColor(.secondary)
    }
    .padding(.top, 5)
    .onAppear {
      heal()
    }
    .onChange(of: durations) { _, newValue in
      heal(entries: newValue)
    }
  }

  private func heal(entries: [UnblockDurationEntry]? = nil) {
    let list = entries ?? durations
    let healed = selection.healed(durations: list)
    if healed != selection {
      selection = healed
    }
  }
}
