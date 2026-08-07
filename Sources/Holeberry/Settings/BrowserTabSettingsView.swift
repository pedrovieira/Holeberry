import SwiftUI

/// The "Browser Tab" section of the General settings tab: the unblocking
/// toggle, its info popover, and the explanatory sublabel.
struct BrowserTabSettingsView: View {
  @Binding var isEnabled: Bool

  @State private var showingBrowserInfo = false

  var body: some View {
    Section("Browser Tab") {
      VStack(alignment: .leading) {
        HStack(spacing: 6) {
          Text("Enable browser tab unblocking")

          Button {
            showingBrowserInfo.toggle()
          } label: {
            Image(systemName: "info.circle")
              .font(.system(size: 11))
              .foregroundColor(.secondary)
          }
          .buttonStyle(.plain)
          .popover(isPresented: $showingBrowserInfo) {
            BrowserTabInfoPopover {
              showingBrowserInfo = false
            }
          }

          Spacer()

          Toggle("", isOn: $isEnabled)
            .labelsHidden()
            .accessibilityLabel("Enable browser tab unblocking")
        }

        Text("May require Automation permission to read the current browser tab URL.")
          .font(.callout)
          .foregroundColor(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}

/// Popover with details about browser tab unblocking: the supported engines,
/// the experimental Firefox/Zen support, and a link to the full browser list.
private struct BrowserTabInfoPopover: View {
  /// Called when the user opens the full browser list so the popover can close.
  let onOpenFullList: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Browser Tab Unblocking")
        .font(.system(size: 12, weight: .semibold))

      Text("Holeberry can unblock the domain from your current browser tab. It supports:")
        .font(.system(size: 11))
        .foregroundColor(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      VStack(alignment: .leading, spacing: 2) {
        Text("• Safari")
        Text("• Chromium (Chrome, etc.)")
        Text("• Gecko (Firefox)")
      }
      .font(.system(size: 11))

      Text("Support for Firefox and Zen Browser is experimental and not fully tested.")
        .font(.system(size: 11))
        .foregroundColor(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      Button {
        onOpenFullList()
        if let url = URL(string: "https://github.com/pedrovieira/Holeberry/blob/main/docs/SUPPORTED-BROWSERS.md") {
          NSWorkspace.shared.open(url)
        }
      } label: {
        HStack(spacing: 3) {
          Text("Full list of supported browsers")
          Image(systemName: "arrow.up.right")
            .font(.system(size: 9))
        }
      }
      .buttonStyle(.plain)
      .font(.system(size: 11))
      .foregroundColor(.accentColor)
    }
    .padding(12)
    .frame(width: 260)
  }
}
