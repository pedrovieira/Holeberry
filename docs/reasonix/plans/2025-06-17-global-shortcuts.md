# Global Shortcuts Implementation Plan

> **For agentic workers:** implement this plan task-by-task — dispatch a fresh subagent per task with the native `task` tool (recommended for quality), or use the superpowers-executing-plans skill to work through it inline. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add global keyboard shortcuts (via sindresorhus/KeyboardShortcuts) to toggle Pi-hole blocking on all configured servers from anywhere, plus a Shortcuts settings tab with recorder controls.

**Architecture:** A dedicated `ShortcutController` (@MainActor) registers 6 `onKeyDown` listeners at startup. Each listener iterates all servers from `ServerStatusMonitor.shared` and calls `setBlocking`. The `disableCustom` shortcut opens an NSAlert duration picker. On API failure, a system notification is posted; tapping it opens Settings. A new `.shortcuts` tab in SettingsView exposes `KeyboardShortcuts.Recorder` controls.

**Tech Stack:** Swift 5.9, macOS 14+, KeyboardShortcuts (SPM, sindresorhus), UserNotifications

**Design spec:** `docs/reasonix/specs/2025-06-17-global-shortcuts-design.md`

---

## File Map

| File | Action | Responsibility |
|---|---|---|
| `Package.swift` | Modify | Add KeyboardShortcuts SPM dependency |
| `Sources/PiHoleMenuApp/Utils/ShortcutNames.swift` | Create | Define 6 shortcut name constants |
| `Sources/PiHoleMenuApp/App/ShortcutController.swift` | Create | Register onKeyDown listeners, fire setBlocking on all servers, handle errors with notifications |
| `Sources/PiHoleMenuApp/Settings/SettingsView.swift` | Modify | Add `.shortcuts` tab with 6 Recorder rows |
| `Sources/PiHoleMenuApp/PiHoleMenuApp.swift` | Modify | Instantiate ShortcutController, request notification auth, handle notification taps |

**NOT modified:** `MenuBuilder.swift`, `MenuContentView.swift`, `MenuBarController.swift`, `ServerStatusMonitor.swift`

---

### Task 1: Add KeyboardShortcuts SPM dependency

**Files:**
- Modify: `Package.swift:9-12` (dependencies array), `Package.swift:17` (executableTarget dependencies)

- [ ] **Step 1: Add package dependency to Package.swift**

Add the KeyboardShortcuts package URL to the `dependencies` array, and add `"KeyboardShortcuts"` to the executable target dependencies.

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "PiHoleMenuApp",
  platforms: [
    .macOS(.v14)
  ],
  dependencies: [
    .package(url: "https://github.com/auth0/SimpleKeychain", from: "1.3.0"),
    .package(url: "https://github.com/realm/SwiftLint", from: "0.55.0"),
    .package(url: "https://github.com/sindresorhus/Defaults", from: "9.0.0"),
    .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "2.4.0")
  ],
  targets: [
    .executableTarget(
      name: "PiHoleMenuApp",
      dependencies: ["SimpleKeychain", "Defaults", "KeyboardShortcuts"],
      exclude: ["Info.plist", "Resources"],
      plugins: [.plugin(name: "SwiftLintBuildToolPlugin", package: "SwiftLint")]
    ),
    .testTarget(
      name: "PiHoleMenuAppTests",
      dependencies: ["PiHoleMenuApp"],
      plugins: [.plugin(name: "SwiftLintBuildToolPlugin", package: "SwiftLint")]
    )
  ]
)
```

- [ ] **Step 2: Resolve packages and verify build**

Run: `cd /Users/pedrovieira/.superset/worktrees/cf933654-bfc7-4215-abd8-c4d423c9955c/field-guarantee && swift package resolve`

Expected: Package resolves successfully, KeyboardShortcuts fetched.

Run: `swift build 2>&1 | tail -5`

Expected: Build succeeds (no errors from missing module).

- [ ] **Step 3: Commit**

```bash
git add Package.swift Package.resolved
git commit -m "build: add KeyboardShortcuts SPM dependency (checkpoint 7)"
```

---

### Task 2: Create ShortcutNames.swift

**Files:**
- Create: `Sources/PiHoleMenuApp/Utils/ShortcutNames.swift`

- [ ] **Step 1: Create the file with the KeyboardShortcuts.Name extension**

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

- [ ] **Step 2: Verify it compiles**

Run: `cd /Users/pedrovieira/.superset/worktrees/cf933654-bfc7-4215-abd8-c4d423c9955c/field-guarantee && swift build 2>&1 | tail -5`

Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/PiHoleMenuApp/Utils/ShortcutNames.swift
git commit -m "feat: add ShortcutNames extension (checkpoint 7)"
```

---

### Task 3: Create ShortcutController.swift

**Files:**
- Create: `Sources/PiHoleMenuApp/App/ShortcutController.swift`

- [ ] **Step 1: Create ShortcutController with all 6 onKeyDown listeners**

```swift
import AppKit
import KeyboardShortcuts
import OSLog
import UserNotifications

@MainActor
final class ShortcutController {
    private let logger = Logger(subsystem: Logger.appSubsystem, category: "shortcuts")

    init() {
        registerShortcuts()
    }

    // MARK: - Registration

    private func registerShortcuts() {
        KeyboardShortcuts.onKeyDown(for: .disableIndefinitely) { [weak self] in
            await self?.setBlockingOnAll(enabled: false, duration: nil)
        }
        KeyboardShortcuts.onKeyDown(for: .disable10s) { [weak self] in
            await self?.setBlockingOnAll(enabled: false, duration: 10)
        }
        KeyboardShortcuts.onKeyDown(for: .disable30s) { [weak self] in
            await self?.setBlockingOnAll(enabled: false, duration: 30)
        }
        KeyboardShortcuts.onKeyDown(for: .disable5m) { [weak self] in
            await self?.setBlockingOnAll(enabled: false, duration: 300)
        }
        KeyboardShortcuts.onKeyDown(for: .disableCustom) { [weak self] in
            await self?.promptCustomDurationThenSetBlocking()
        }
        KeyboardShortcuts.onKeyDown(for: .reEnableBlocking) { [weak self] in
            await self?.setBlockingOnAll(enabled: true, duration: nil)
        }
    }

    // MARK: - Blocking

    private func setBlockingOnAll(enabled: Bool, duration: TimeInterval?) async {
        let monitor = ServerStatusMonitor.shared
        let servers = monitor.servers

        guard !servers.isEmpty else {
            logger.debug("Shortcut fired but no servers configured — skipping")
            return
        }

        var firstError: String?
        for server in servers {
            do {
                try await monitor.setBlocking(for: server, enabled: enabled, duration: duration)
            } catch {
                logger.warning("Shortcut setBlocking failed for \(server.label ?? server.url): \(error.localizedDescription, privacy: .public)")
                if firstError == nil {
                    firstError = error.localizedDescription
                }
            }
        }

        if let errorMessage = firstError {
            await postErrorNotification(action: enabled ? "enable" : "disable", error: errorMessage)
        }
    }

    // MARK: - Custom Duration

    private func promptCustomDurationThenSetBlocking() async {
        let monitor = ServerStatusMonitor.shared
        guard !monitor.servers.isEmpty else {
            logger.debug("disableCustom shortcut fired but no servers configured — skipping")
            return
        }

        // Show NSAlert with text field on main thread, then get the result
        let seconds = await MainActor.run { () -> TimeInterval? in
            let alert = NSAlert()
            alert.messageText = "Custom Disable Time"
            alert.informativeText = "Enter the number of seconds to disable blocking."
            alert.addButton(withTitle: "Disable")
            alert.addButton(withTitle: "Cancel")

            let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
            textField.placeholderString = "e.g. 120"
            alert.accessoryView = textField
            alert.window.initialFirstResponder = textField

            let response = alert.runModal()
            guard response == .alertFirstButtonReturn else { return nil }

            let text = textField.stringValue.trimmingCharacters(in: .whitespaces)
            guard let seconds = TimeInterval(text), seconds > 0 else { return nil }
            return seconds
        }

        guard let duration = seconds else { return }
        await setBlockingOnAll(enabled: false, duration: duration)
    }

    // MARK: - Error Notification

    private func postErrorNotification(action: String, error: String) async {
        let content = UNMutableNotificationContent()
        content.title = "Pi-hole Menu Bar"
        content.body = "Failed to \(action) blocking: \(error)"
        content.categoryIdentifier = "SHORTCUT_ERROR"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "shortcut-error-\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )

        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            logger.error("Failed to post error notification: \(error.localizedDescription, privacy: .public)")
        }
    }
}
```

- [ ] **Step 2: Verify it compiles**

Run: `cd /Users/pedrovieira/.superset/worktrees/cf933654-bfc7-4215-abd8-c4d423c9955c/field-guarantee && swift build 2>&1 | tail -10`

Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/PiHoleMenuApp/App/ShortcutController.swift
git commit -m "feat: add ShortcutController with global shortcut listeners (checkpoint 7)"
```

---

### Task 4: Add Shortcuts tab to SettingsView

**Files:**
- Modify: `Sources/PiHoleMenuApp/Settings/SettingsView.swift`

This task makes three changes: (a) add `.shortcuts` case to the `SettingsTab` enum with an icon, (b) add the `.shortcuts` case to the `body` switch, (c) add the `shortcutsSection` view builder.

- [ ] **Step 1: Add .shortcuts case to SettingsTab enum**

In `SettingsTab`, add the new case and its icon. Replace lines 6-22:

```swift
enum SettingsTab: String, CaseIterable {
  case server = "Server"
  case defaults = "Defaults"
  case shortcuts = "Shortcuts"
  case advanced = "Advanced"
  case notifications = "Notifications"
  case about = "About"

  var icon: String {
    switch self {
    case .server: return "server.rack"
    case .defaults: return "slider.horizontal.3"
    case .shortcuts: return "keyboard"
    case .advanced: return "gearshape.2"
    case .notifications: return "bell"
    case .about: return "info.circle"
    }
  }
}
```

- [ ] **Step 2: Add .shortcuts case to the body switch**

In the `detail:` closure of the `NavigationSplitView`, add the `.shortcuts` case between `.defaults` and `.advanced`. Replace lines 46-67:

```swift
    } detail: {
      switch selectedTab {
      case .server:
        Form {
          ConnectionListView()
        }
        .formStyle(.grouped)
      case .defaults:
        Form { defaultsSection }
          .formStyle(.grouped)
      case .shortcuts:
        Form { shortcutsSection }
          .formStyle(.grouped)
      case .advanced:
        Form { advancedSection }
          .formStyle(.grouped)
      case .notifications:
        Form {
          Section("Notifications") {
            Label("Notify on block", systemImage: "bell")
          }
        }
        .formStyle(.grouped)
      case .about:
        aboutView
      }
    }
```

- [ ] **Step 3: Add shortcutsSection view builder**

Add the following computed property inside the `SettingsView` struct, after the `defaultsSection` property (after line 123):

```swift
  private var shortcutsSection: some View {
    Section("Global Shortcuts") {
      KeyboardShortcuts.Recorder("Disable Indefinitely:", name: .disableIndefinitely)
      KeyboardShortcuts.Recorder("Disable 10 seconds:", name: .disable10s)
      KeyboardShortcuts.Recorder("Disable 30 seconds:", name: .disable30s)
      KeyboardShortcuts.Recorder("Disable 5 minutes:", name: .disable5m)
      KeyboardShortcuts.Recorder("Custom duration...:", name: .disableCustom)
      KeyboardShortcuts.Recorder("Re-enable Blocking:", name: .reEnableBlocking)
    } footer: {
      Text("Shortcuts work globally even when the app is in the background. Press Escape in a recorder to clear a shortcut.")
        .foregroundStyle(.secondary)
    }
  }
```

- [ ] **Step 4: Verify it compiles**

Run: `cd /Users/pedrovieira/.superset/worktrees/cf933654-bfc7-4215-abd8-c4d423c9955c/field-guarantee && swift build 2>&1 | tail -10`

Expected: Build succeeds. The `swift build` command picks up the new `.shortcuts` case in the exhaustive switch automatically.

- [ ] **Step 5: Commit**

```bash
git add Sources/PiHoleMenuApp/Settings/SettingsView.swift
git commit -m "feat: add Shortcuts tab to Settings with Recorder controls (checkpoint 7)"
```

---

### Task 5: Wire up AppDelegate — instantiate ShortcutController + notification handling

**Files:**
- Modify: `Sources/PiHoleMenuApp/PiHoleMenuApp.swift`

This task: (a) adds `import UserNotifications`, (b) stores a `ShortcutController` instance, (c) requests notification authorization, (d) sets up the notification delegate to open Settings on tap.

- [ ] **Step 1: Replace PiHoleMenuApp.swift with the updated version**

```swift
import AppKit
import SwiftUI
import UserNotifications

@main
struct PiHoleMenuApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

  var body: some Scene {
    WindowGroup(id: "hidden") {
      Color.clear
        .frame(width: 0, height: 0)
        .hidden()
    }
    .windowResizability(.contentSize)
    .defaultSize(width: 0, height: 0)
  }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
  private var menuBarController: MenuBarController?
  private var shortcutController: ShortcutController?

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)

    // Request notification authorization for shortcut error alerts
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
      if let error {
        Logger(subsystem: Logger.appSubsystem, category: "app-delegate")
          .warning("Notification authorization denied: \(error.localizedDescription, privacy: .public)")
      }
    }
    UNUserNotificationCenter.current().delegate = self

    ServerStatusMonitor.shared.startPolling()
    menuBarController = MenuBarController(tempUnblockManager: .shared)
    shortcutController = ShortcutController()
  }

  func applicationWillTerminate(_ notification: Notification) {
    Task {
      await ServerStatusMonitor.shared.logoutAll()
    }
  }
}

// MARK: - UNUserNotificationCenterDelegate

extension AppDelegate: UNUserNotificationCenterDelegate {
  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    // Show notification even when app is in foreground
    completionHandler([.banner, .sound])
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    if response.notification.request.content.categoryIdentifier == "SHORTCUT_ERROR" {
      SettingsWindowController.shared.showWindow()
    }
    completionHandler()
  }
}
```

- [ ] **Step 2: Verify it compiles**

Run: `cd /Users/pedrovieira/.superset/worktrees/cf933654-bfc7-4215-abd8-c4d423c9955c/field-guarantee && swift build 2>&1 | tail -10`

Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/PiHoleMenuApp/PiHoleMenuApp.swift
git commit -m "feat: wire ShortcutController + notification handling in AppDelegate (checkpoint 7)"
```

---

### Task 6: Manual verification

**No code changes.** Follow the checklist from the design spec.

- [ ] **Step 1: Record a shortcut**
  - Open Settings → Shortcuts tab
  - Click the "Disable Indefinitely" Recorder row
  - Type `⌃⌥⌘D`
  - Verify the shortcut displays correctly in the recorder

- [ ] **Step 2: Trigger blocking via shortcut**
  - Ensure at least one Pi-hole server is configured and connected
  - Background the app (click away)
  - Press `⌃⌥⌘D`
  - Verify the menu bar icon changes to reflect blocking disabled state

- [ ] **Step 3: Trigger custom duration**
  - Press the shortcut assigned to "Custom duration..."
  - Verify an NSAlert with a text field appears
  - Enter a duration (e.g. `60`) and click "Disable"
  - Verify blocking is disabled on all servers

- [ ] **Step 4: Re-enable blocking**
  - Press the shortcut assigned to "Re-enable Blocking"
  - Verify blocking is re-enabled on all servers

- [ ] **Step 5: Persistence**
  - Quit and restart the app
  - Open Settings → Shortcuts
  - Verify the previously recorded shortcuts are still displayed

- [ ] **Step 6: Clear a shortcut**
  - Click a recorder, press Escape
  - Verify it shows "None" or placeholder text
  - Press the now-cleared shortcut → verify nothing happens

- [ ] **Step 7: No servers edge case**
  - Delete all servers from Settings → Server
  - Press any blocking shortcut
  - Verify nothing crashes, no notification appears (silent no-op)

- [ ] **Step 8: Error notification** (requires network disruption)
  - With servers configured, disconnect network or stop Pi-hole
  - Press a blocking shortcut
  - Verify a system notification appears with error text
  - Click the notification → verify Settings window opens
