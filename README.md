<p align="center">
  <img src="Sources/Holeberry/Resources/AppIcon.icon/Assets/logo_transparent.png" alt="Holeberry" width="128" />
</p>

<h1 align="center">Holeberry</h1>

<p align="center">
  <a href="README.md">English</a> ·
  <a href="README.zh-CN.md">简体中文</a> ·
  <a href="README.ja.md">日本語</a> ·
  <a href="https://holeberryapp.com">Website</a>
</p>

<p align="center">
  <b>Your Pi-hole, right in the menu bar.</b><br />
  A native and modern macOS menu bar app to monitor and control your Pi-hole instances — no browser tab required.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-14%2B-000000?logo=apple&logoColor=white&style=flat-square" alt="macOS 14+" />
  <img src="https://img.shields.io/badge/Swift-6.0-orange?logo=swift&logoColor=white&style=flat-square" alt="Swift 6.0" />
  <img src="https://img.shields.io/badge/license-MIT-blue.svg?style=flat-square" alt="MIT License" />
  <img src="https://img.shields.io/github/v/release/pedrovieira/Holeberry?style=flat-square" alt="Latest release" />
  <img src="https://img.shields.io/badge/Pi--hole-v5%20%26%20v6-96C93C.svg?style=flat-square" alt="Pi-hole v5 & v6" />
</p>

<!-- TODO: Replace with a screenshot of the menu bar icon + open popup in context. This is the single most important visual of the README — show the status menu with the colored dot, stats line, and the Disable Blocking submenu. -->

## What is Holeberry?

Holeberry is a lightweight macOS menu bar app that puts your Pi-hole at your fingertips. Check blocking status and query stats, disable blocking for a few seconds or a custom duration, unblock the domain in your current browser tab, and allowlist or unblock recently-blocked domains — all without opening the Pi-hole web interface.

It supports Pi-hole **v5 and v6**, multiple instances, and global keyboard shortcuts.

## Installation

### GitHub Releases (recommended)

1. Download the latest `Holeberry-<version>.dmg` from the [Releases](https://github.com/pedrovieira/Holeberry/releases) page.
2. Open the DMG and drag **Holeberry** into your `Applications` folder.
3. Launch Holeberry — it lives in your menu bar.

**Note on macOS Gatekeeper:** Holeberry is built with a free Apple ID, so the app is not notarized with a paid Apple Developer account. macOS may therefore flag it as an unidentified developer or quarantine it on first launch. If you see that warning, remove the quarantine flag and launch again:

```bash
xattr -dr com.apple.quarantine /Applications/Holeberry.app
```

Holeberry checks for updates automatically via [Sparkle](https://sparkle-project.org/).

### Homebrew

A Homebrew cask is planned. Until then, use the release DMG above.

## Requirements

- **macOS 14 (Sonoma) or later** — Holeberry is built with Swift 6 and takes advantage of modern macOS APIs.
- A Pi-hole instance (v5 or v6) reachable from your Mac, on your local network or elsewhere.

## Features

### Status at a glance

The menu bar icon reflects your Pi-hole's health at all times, with per-instance status for multi-server setups:

- 🟢 **Blocking Active** — everything is blocking as expected
- ⚪ **Blocking Disabled** — blocking is off (or on a timer)
- 🟠 **Blocking Partially Active** — your instances disagree with each other
- 🔴 **Instance Unreachable** — one or more instances can't be reached

The menu also shows **total queries and blocked domains** across all your instances.

### Disable blocking with a timer

Turn blocking off for **10 seconds, 30 seconds, 5 minutes, a custom duration**, or **indefinitely** — blocking re-enables automatically when the timer expires. No more forgetting to turn the ads back on.

### Unblock the tab you're on

Holeberry detects the current tab in **Safari, Chrome/Chromium, Firefox, and Zen Browser** and lets you unblock that exact domain — for 10 seconds, 30 seconds, 5 minutes, or a custom duration — or add it to your allowlist. Perfect for that one broken link or video that refuses to load.

### Recently blocked

Browse the domains Pi-hole blocked recently (from your Mac or all clients), and unblock or allowlist any of them straight from the menu.

### Multiple instances

Manage several Pi-hole instances from one menu: per-server status dots, aggregated query/blocked stats, and clear warnings when an instance is down or instances disagree on blocking state.

### Pi-hole v5 & v6

Holeberry detects the Pi-hole version automatically and talks to each the right way — the v5 web API or the v6 REST API with session authentication. Credentials are stored securely in the macOS **Keychain**, never in plain text.

### Global keyboard shortcuts

Assign global shortcuts to disable blocking (10s / 30s / 5 min / custom / indefinitely), re-enable blocking, and unblock the current tab — they work even when Holeberry is in the background.

### Auto-discovery

Holeberry finds Pi-hole instances automatically — by scanning your local network and checking the DNS servers your Mac is currently using (so remote setups like a Pi-hole over Tailscale or a VPN are found too). Getting set up is often just "click and connect".

## Why Holeberry?

Pi-hole's web interface is great — for when you're already in a browser. But every quick action meant a trip to `pi.hole/admin`: toggle blocking, wait for the page, click again, then remember to re-enable. And the macOS clients I tried were missing the workflows I actually use: unblocking the exact domain in the tab I'm looking at, per-domain timers, and a truthful at-a-glance status across multiple instances.

So I built Holeberry: a native, menu-bar-only app that treats Pi-hole control like a first-class macOS citizen — fast, keyboard-driven, and honest about what your network is doing.

The name? Pi-hole runs on a Raspberry Pi, and well — *berry* felt right.

It's also a labor of love in engineering: Swift 6 with strict concurrency, a protocol-driven core extracted into a local Swift package (`HoleberryCore`), and a heavily tested service layer — the kind of codebase I'd want to read as an open-source contributor.

## What's next?

Holeberry is a Pi-hole app today, but the menu bar workflow doesn't have to stop there. If there's enough community interest, future versions could add:

- **Support for other DNS providers** — AdGuard Home and Technitium are natural candidates, for people who don't run Pi-hole.
- **Mixed setups** — connect Pi-hole and AdGuard Home (or any combination) side by side, with per-instance status, aggregated stats, and the same one-click controls across providers.

None of this is a commitment — it's a wishlist, and demand decides the order. If you'd like to see any of these, open an [issue](https://github.com/pedrovieira/Holeberry/issues) and say so; the more support an idea gets, the higher it climbs.

## Getting started

1. **Add your Pi-hole** — via auto-discovery or manually (URL, API token / password, and an optional label and icon).
2. **Grant permissions** when prompted:
   - **Local Network** — to reach your Pi-hole instances.
   - **Automation** — only if you enable browser-tab unblocking; Holeberry reads the current tab URL from your browser to unblock it.
3. **Set your shortcuts** — in Settings → Shortcuts, or leave the defaults.

That's it. Everything else lives in the menu bar.

## Screenshots

<!-- TODO: Add screenshots here — menu bar popup (status + controls), the browser-tab unblock section, the Settings window (Servers / Shortcuts tabs). -->

## FAQ

### Does Holeberry support Pi-hole v5 and v6?
Yes. The version is detected automatically, and each instance is configured with the right API. Credentials for v6 sessions are refreshed automatically and stored in the macOS Keychain.

### Where are my Pi-hole credentials stored?
In the macOS **Keychain** — the same secure storage used by Mail, Safari, and your system. Holeberry never writes passwords to disk.

### What permissions does Holeberry need, and why?
- **Local Network**: required to connect to your Pi-hole instances.
- **Automation** (browser access): optional, only used when browser-tab unblocking is enabled. You can disable it anytime in Settings → General.

### Does Holeberry replace the Pi-hole web interface?
No — and it's not meant to. Holeberry is the remote control for the actions you take daily: status, toggling, and targeted unblocking. For deep configuration (adlists, DHCP, gravity updates), the web interface remains the tool.

### Is Holeberry free?
Yes — it's open source under the [MIT license](LICENSE), free to use, fork, and learn from.

### Why doesn't my browser tab appear?
Browser-tab unblocking must be enabled in Settings → General, and Holeberry needs Automation permission for your browser (granted via System Settings on first use).

## Building from source

```bash
git clone https://github.com/pedrovieira/Holeberry.git
cd Holeberry
open Holeberry.xcodeproj
```

Select the **Holeberry** scheme and hit Run (⌘R).

Notes for contributors:

- The project uses [XcodeGen](https://github.com/yonaskolb/XcodeGen) — if you change `project.yml`, regenerate with `xcodegen generate`.
- The app target has pre-build scripts running [SwiftLint](https://github.com/realm/SwiftLint) and `swift-format` in strict mode; install them or the build will warn.
- Core logic lives in the `HoleberryCore` Swift package with its own test suite — `cd Packages/HoleberryCore && swift test`.

## Project structure

```
Holeberry/
├── project.yml                  # XcodeGen spec — regenerate with `xcodegen generate`
├── Sources/Holeberry/           # App target (menu bar UI only)
│   ├── App/                     # app lifecycle + updater
│   ├── MenuBar/                 # menu bar controllers & builders
│   ├── Components/              # reusable UI views
│   ├── Shortcuts/               # global keyboard shortcuts
│   ├── Settings/                # settings window UI
│   ├── Support/                 # Info.plist, entitlements
│   └── Resources/               # assets, app icon
└── Packages/HoleberryCore/      # business logic, with its own test suite
    ├── Sources/HoleberryCore/
    │   ├── Models/              # value types
    │   ├── Networking/          # HTTP layer, reachability, retry
    │   ├── Persistence/         # keychain + defaults keys
    │   ├── Services/            # Auth, BrowserDetector, Pihole services
    │   └── Utils/               # generic utilities
    └── Tests/HoleberryCoreTests/
```

## Contributing

Bug reports and feature requests are welcome via [issues](https://github.com/pedrovieira/Holeberry/issues). PRs should target the `main` branch, and the existing test suites should pass. AI-assisted contributions are welcome — if your PR was produced with AI assistance, please note it in the PR description and name the tool you used. Please open an issue first if you're planning something substantial — it saves both of us time.

## AI-assisted development

This project was primarily written by AI. I want to be upfront about that — but it was heavily guided by a human: me. AI generated and refined most of the code, but the architecture, the features, the scope, and the design decisions were directed and reviewed by me at every step. Treat the AI as an accelerator, not an author: the choices that make this codebase what it is — protocol-driven design, a testable core extracted into `HoleberryCore`, Swift 6 strict concurrency — are human choices. AI just made it faster to get there.

## Acknowledgements

- [Sparkle](https://github.com/sparkle-project/Sparkle) — update framework
- [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) — global shortcut recording
- [Defaults](https://github.com/sindresorhus/Defaults) — typed user defaults
- [SymbolPicker](https://github.com/SzpakKamil/SymbolPicker) — instance icon picker
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) — project generation
- [SwiftLint](https://github.com/realm/SwiftLint) and `swift-format` — keeping the code honest

## License

[MIT](LICENSE) © 2026 Pedro Vieira

---

*Pi-hole® is a registered trademark of Pi-hole LLC. Holeberry is an independent project and is not affiliated with Pi-hole LLC.*
