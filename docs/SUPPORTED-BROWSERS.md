# Supported Browsers

Holeberry can read the domain from your current browser tab and unblock it. This page lists every browser Holeberry supports, grouped by the engine they're built on. The list mirrors the `Browser` enum in `Packages/HoleberryCore/Sources/HoleberryCore/Services/BrowserDetector/Browser.swift`.

## WebKit

| Browser | Bundle ID |
| --- | --- |
| Safari | `com.apple.Safari` |
| Safari Technology Preview | `com.apple.SafariTechnologyPreview` |
| Orion | `com.kagi.kagimacOS` |
| Orion RC | `com.kagi.kagimacOS.RC` |

## Chromium (Blink)

| Browser | Bundle ID |
| --- | --- |
| Google Chrome | `com.google.Chrome` |
| Google Chrome Beta | `com.google.Chrome.beta` |
| Google Chrome Dev | `com.google.Chrome.dev` |
| Google Chrome Canary | `com.google.Chrome.canary` |
| Microsoft Edge | `com.microsoft.edgemac` |
| Microsoft Edge Beta | `com.microsoft.edgemac.beta` |
| Microsoft Edge Dev | `com.microsoft.edgemac.dev` |
| Microsoft Edge Canary | `com.microsoft.edgemac.canary` |
| Brave Browser | `com.brave.Browser` |
| Brave Browser Beta | `com.brave.Browser.beta` |
| Brave Browser Nightly | `com.brave.Browser.nightly` |
| Arc | `company.thebrowser.Browser` |
| Opera | `com.operasoftware.Opera` |
| Opera Next | `com.operasoftware.OperaNext` |
| Opera Developer | `com.operasoftware.OperaDeveloper` |
| Vivaldi | `com.vivaldi.Vivaldi` |
| Vivaldi Snapshot | `com.vivaldi.Vivaldi.snapshot` |

## Gecko (Firefox)

| Browser | Bundle ID |
| --- | --- |
| Firefox | `org.mozilla.firefox` |
| Firefox Developer Edition | `org.mozilla.firefoxdeveloperedition` |
| Firefox Nightly | `org.mozilla.nightly` |
| Zen Browser | `app.zen-browser.zen` |

## How tab detection works

- **WebKit (Safari, Orion) and Chromium-based browsers** — Holeberry uses AppleScript to ask the browser for its active tab URL. macOS asks for Automation permission on first use (System Settings → Privacy & Security → Automation); without it, tab detection is unavailable for that browser.
- **Firefox and Zen Browser** — Holeberry reads the browser's `sessionstore.jsonlz4` file directly, so no Automation permission is needed. This method is **experimental and not fully tested** and may break with future browser versions.

  > **Note:** It may take a few seconds for the current tab's URL to become available — these browsers write their session store to disk in their own time.

## Missing a browser?

Holeberry is an independent, open-source project. If your browser is not listed, open an issue on GitHub — new browsers are easy to add.
