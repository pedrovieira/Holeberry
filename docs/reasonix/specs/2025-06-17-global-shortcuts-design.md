# Global Shortcuts for Blocking/Unblocking — Design Spec

> Checkpoint 7 of the Pi-hole Menu Bar App implementation plan.
> Date: 2025-06-17

## Overview

Add global keyboard shortcuts to toggle Pi-hole blocking without opening the menu. Uses
[sindresorhus/KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) — a Swift-native
library providing `KeyboardShortcuts.Recorder` (settings UI) and global `onKeyDown` listeners. Fully
sandbox-compatible, no Input Monitoring permission required.

Shortcuts target **all configured servers** simultaneously. No per-server shortcut configuration.

## Shortcuts Defined

| Shortcut | Name constant | Action |
|---|---|---|
| Disable Indefinitely | `.disableIndefinitely` | `setBlocking(enabled: false, duration: nil)` on all servers |
| Disable 10 seconds | `.disable10s` | `setBlocking(enabled: false, duration: 10)` on all servers |
| Disable 30 seconds | `.disable30s` | `setBlocking(enabled: false, duration: 30)` on all servers |
| Disable 5 minutes | `.disable5m` | `setBlocking(enabled: false, duration: 300)` on all servers |
| Custom duration... | `.disableCustom` | Opens CustomTimePanel (NSPanel); on confirm, `setBlocking` on all servers |
| Re-enable Blocking | `.reEnableBlocking` | `setBlocking(enabled: true, duration: nil)` on all servers |

## Architecture

### New Files

```
Sources/PiHoleMenuApp/
├── Utils/
│   └── ShortcutNames.swift          ← NEW
└── App/
    └── ShortcutController.swift     ← NEW
```

### Modified Files

```
Sources/PiHoleMenuApp/
├── PiHoleMenuApp.swift              ← instantiate ShortcutController on launch
├── Settings/
│   └── SettingsView.swift           ← add .shortcuts tab with Recorder rows
└── Package.swift                    ← add KeyboardShortcuts dependency
```

### Components

#### ShortcutNames.swift

Extension on `KeyboardShortcuts.Name` with six `static let` constants. Each uses `Self("camelCaseName")`
— the library uses these strings as UserDefaults keys internally. No other logic.

```swift
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let disableIndefinitely = Self("disableIndefinitely")
    static let disable10s = Self("disable10s")
    static let disable30s = Self("disable30s")
    static let disable5m = Self("disable5m")
    static let disableCustom = Self("disableCustom")
    static let reEnableBlocking = Self("reEnableBlocking")
}
```

#### ShortcutController.swift

`@MainActor` class. Created once at app startup (after `MenuBarController.setup()`). Registers all six
`KeyboardShortcuts.onKeyDown` listeners. Each listener:

1. Checks `ServerStatusMonitor.shared.servers.isEmpty` → silent no-op if empty
2. Calls `ServerStatusMonitor.shared.setBlocking(for:, enabled:, duration:)` for each server
3. On failure: posts a system notification via `UNUserNotificationCenter`
4. Uses `[weak self]` to avoid retain cycles

`disableCustom` opens the `CustomTimePanel` as a floating NSPanel instead of calling `setBlocking` directly.

#### SettingsView.swift Changes

- Add `.shortcuts` case to the `SettingsTab` enum
- New tab body: Form with section header "Global Shortcuts", six `KeyboardShortcuts.Recorder` rows, and
  a footer explaining global behavior and how to clear a shortcut
- No manual persistence code — the library handles UserDefaults automatically

#### PiHoleMenuApp.swift Changes

- In `AppDelegate.applicationDidFinishLaunching`, after the existing `MenuBarController` setup,
  instantiate and retain `ShortcutController`:
  ```swift
  private var shortcutController: ShortcutController?
  // ...
  shortcutController = ShortcutController()
  ```

## Data Flow

### Shortcut Trigger (normal actions)

```
User presses global shortcut
  → KeyboardShortcuts fires onKeyDown callback
  → ShortcutController iterates ServerStatusMonitor.shared.servers
  → For each server: setBlocking(for: serverId, enabled: <bool>, duration: <seconds?>)
  → ServerStatusMonitor publishes updated status → MenuBarController updates icon
  → TimerManager starts countdown (if applicable)
```

### Shortcut Trigger (custom duration)

```
User presses .disableCustom shortcut
  → ShortcutController opens CustomTimePanel (NSPanel)
  → User enters duration → confirms
  → Panel calls setBlocking on all servers
  → Panel closes
```

### Settings Recording

```
User clicks Recorder → types ⌃⌥⌘D
  → KeyboardShortcuts library persists to UserDefaults automatically
  → Conflict with system shortcut? Library shows built-in warning dialog
```

### Error Notification

```
Shortcut fires → setBlocking fails (network down, server unreachable)
  → ShortcutController catches error
  → Posts UNUserNotificationCenter notification:
      Title: "Pi-hole Menu Bar"
      Body: "Failed to disable blocking: <error description>"
      Category: opens Settings on click
```

## Edge Cases

| Scenario | Behavior |
|---|---|
| No servers configured | Silent no-op |
| Shortcut while already in target state | Idempotent — Pi-hole returns success; no visible change |
| Shortcut cleared by user | `KeyboardShortcuts.getShortcut(for:)` returns nil; callback never fires |
| System shortcut conflict | Library shows built-in conflict dialog |
| App not running | Shortcut has no effect |
| Rapid repeated presses | Each fires independently; `setBlocking` calls queue via async/await |
| Network/API failure | System notification with error text; click opens Settings |

## What Is NOT Included

- **No menu item shortcut display** — shortcuts are NOT shown next to menu items in the dropdown.
- **No per-server shortcuts** — all shortcuts target all configured servers.
- **No custom notification preferences** — always uses system notifications; no toggle to disable.

## Dependencies

- `KeyboardShortcuts` v2.4+ (SPM, sindresorhus) — same author as existing `Defaults` dependency.

## Verification Checklist

- [ ] Settings → Shortcuts tab → click a Recorder → type `⌃⌥⌘D` → shortcut displays
- [ ] App backgrounded → press `⌃⌥⌘D` → blocking disables on all servers
- [ ] Menu bar icon updates to reflect new blocking state
- [ ] Custom... shortcut opens CustomTimePanel
- [ ] Re-enable shortcut re-enables blocking on all servers
- [ ] Restart app → shortcut still registered
- [ ] Clear shortcut → shows "None" → hotkey no longer triggers
- [ ] No servers configured → shortcut silently does nothing
- [ ] Network down → system notification appears; click opens Settings
