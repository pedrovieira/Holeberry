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
          BetaBadge()

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

        Text(
          "Quickly unblock a URL from your browser. "
            + "May require Automation permission to read the current browser tab."
        )
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
        Text("• WebKit (Safari, Orion)")
        Text("• Chromium (Chrome, etc.)")
        Text("• Gecko (Firefox, Zen, etc.)")
      }
      .font(.system(size: 11))

      Text("Support for Gecko-based browsers is experimental and not fully tested.")
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

/// A small gold "Beta" pill with a gold-brown border, marking the browser tab
/// unblocking feature as experimental: it is not fully tested across all
/// supported browsers.
private struct BetaBadge: View {
  private static let gold = Color(red: 0.85, green: 0.65, blue: 0.13)
  private static let goldBrown = Color(red: 0.60, green: 0.44, blue: 0.06)

  var body: some View {
    Text("Beta")
      .font(.system(size: 10, weight: .semibold))
      .foregroundColor(.black)
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(
        Capsule()
          .fill(Self.gold)
          .overlay(Capsule().strokeBorder(Self.goldBrown, lineWidth: 1))
      )
      .help("Not fully tested for all browsers")
  }
}
