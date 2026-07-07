# Countdown Ring Progress Indicator — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the menu bar countdown text with a custom-drawn capsule containing a progress ring arc, monospaced time text, and shield icon — swapped in only when blocking is disabled with a timer.

**Architecture:** Custom `NSView` subclass (`StatusItemButton`) draws a transparent capsule with a 2pt border. Progress is shown via `CAShapeLayer.strokeEnd` on a second path layer, colored orange (>15%) or red (≤15%). Time text uses `.monospacedDigitSystemFont` for stable width. `MenuBarController` swaps `statusItem.view` between `nil` (normal button) and the custom view during countdown.

**Tech Stack:** AppKit, Swift 6.0, macOS 14.0, Combine, Core Animation (CAShapeLayer), SF Symbols

## Global Constraints

- macOS 14.0 minimum deployment target
- Swift 6.0
- 2-space indentation, 120 char max line length (`.swift-format`)
- File-scoped `private` access level
- No force-unwrap (`!`), no force-try (`try!`)
- Use `NSColor` system semantic colors (no hardcoded hex) to support dark/light mode
- New files go under `Sources/Holeberry/App/`; tests under `Tests/HoleberryTests/`

---

### Task 1: Expose `totalDuration` from `TimerManager`

**Files:**
- Modify: `Sources/Holeberry/Services/TimerManager.swift`

**Interfaces:**
- Consumes: nothing new
- Produces: `@Published var totalDuration: TimeInterval?` — set in `startDisable(duration:)`, cleared in `cancelDisable()`

- [ ] **Step 1: Add `totalDuration` published property**

```swift
import Combine
import Foundation

final class TimerManager: ObservableObject {
  @Published var isDisabled = false
  @Published var remainingSeconds: TimeInterval = 0
  @Published var totalDuration: TimeInterval? = nil   // ← NEW

  private var endTime: ContinuousClock.Instant?
  // ... rest unchanged
```

- [ ] **Step 2: Set `totalDuration` in `startDisable(duration:)`**

Change the `if let duration` branch and the `else` branch to set `totalDuration`:

```swift
  func startDisable(duration: TimeInterval?) {
    isDisabled = true
    totalDuration = duration     // ← NEW
    stopCountdown()
    if let duration {
      endTime = ContinuousClock.now + .seconds(duration)
      remainingSeconds = duration
      startCountdown()
    } else {
      endTime = nil
      remainingSeconds = 0
    }
  }
```

- [ ] **Step 3: Clear `totalDuration` in `cancelDisable()`**

```swift
  func cancelDisable() {
    isDisabled = false
    remainingSeconds = 0
    totalDuration = nil          // ← NEW
    endTime = nil
    stopCountdown()
  }
```

- [ ] **Step 4: Set `totalDuration` in `syncFromRemote(_:)`**

In the `if let remaining, remaining > 0` branch, set `totalDuration = remaining`:

```swift
  func syncFromRemote(_ blockingStatus: BlockingStatus) {
    switch blockingStatus {
    case .enabled:
      cancelDisable()
    case .disabled(let remaining):
      if let remaining, remaining > 0 {
        isDisabled = true
        totalDuration = remaining   // ← NEW (set before remainingSeconds)
        self.remainingSeconds = remaining
        endTime = ContinuousClock.now + .seconds(remaining)
        startCountdown()
      } else {
        startDisable(duration: nil)
      }
    }
  }
```

- [ ] **Step 5: Build to verify no regressions**

```bash
xcodebuild -project Holeberry.xcodeproj -scheme Holeberry -destination 'platform=macOS' build 2>&1 | tail -20
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: Commit**

```bash
git add Sources/Holeberry/Services/TimerManager.swift
git commit -m "feat: expose totalDuration from TimerManager for progress ring fraction"
```

---

### Task 2: Create `StatusItemButton` custom view

**Files:**
- Create: `Sources/Holeberry/App/StatusItemButton.swift`

**Interfaces:**
- Consumes: nothing (standalone view)
- Produces:
  - `final class StatusItemButton: NSView`
  - `func update(remainingSeconds: TimeInterval, totalDuration: TimeInterval?, formattedTime: String)`
  - Override `var intrinsicContentSize: NSSize` — fixed width for "88:88"
  - Internal: `CAShapeLayer` for inactive border and progress arc
  - Internal: `draw(_:)` for shield icon and time text

- [ ] **Step 1: Create the file with skeleton**

```swift
import AppKit

/// Custom menu bar status item view that draws a capsule with a countdown progress ring,
/// a shield icon, and monospaced time text.
final class StatusItemButton: NSView {

  // MARK: - Constants

  private enum Layout {
    static let iconSize: CGFloat = 16
    static let horizontalPadding: CGFloat = 8
    static let iconTextGap: CGFloat = 8
    static let height: CGFloat = 22
    static let borderWidth: CGFloat = 2
    static let fontPointSize: CGFloat = 12
  }

  // MARK: - State

  private var remainingSeconds: TimeInterval = 0
  private var totalDuration: TimeInterval? = nil
  private var formattedTime: String = ""
  private var isUrgent: Bool { progressFraction <= 0.15 && !isIndefinite }
  private var isIndefinite: Bool { totalDuration == nil || (totalDuration ?? 0) <= 0 }
  private var progressFraction: CGFloat {
    guard let total = totalDuration, total > 0 else { return 0 }
    return CGFloat(max(0, min(1, remainingSeconds / total)))
  }

  // MARK: - Layers

  private let inactiveBorderLayer: CAShapeLayer = {
    let layer = CAShapeLayer()
    layer.fillColor = NSColor.clear.cgColor
    layer.strokeColor = NSColor.separatorColor.cgColor
    layer.lineWidth = Layout.borderWidth
    layer.lineCap = .round
    return layer
  }()

  private let progressArcLayer: CAShapeLayer = {
    let layer = CAShapeLayer()
    layer.fillColor = NSColor.clear.cgColor
    layer.lineWidth = Layout.borderWidth
    layer.lineCap = .round
    layer.strokeStart = 0
    layer.strokeEnd = 0
    return layer
  }()

  // MARK: - Font

  private let timeFont: NSFont = {
    .monospacedDigitSystemFont(ofSize: Layout.fontPointSize, weight: .bold)
  }()

  // MARK: - Computed layout

  private var iconRect: NSRect {
    let y = (bounds.height - Layout.iconSize) / 2
    return NSRect(x: Layout.horizontalPadding, y: y, width: Layout.iconSize, height: Layout.iconSize)
  }

  private var textMaxWidth: CGFloat {
    let text = "88:88" as NSString
    let attrs: [NSAttributedString.Key: Any] = [.font: timeFont]
    return text.size(withAttributes: attrs).width
  }

  private var textRect: NSRect {
    let maxW = textMaxWidth
    let text = formattedTime as NSString
    let attrs: [NSAttributedString.Key: Any] = [.font: timeFont]
    let size = text.size(withAttributes: attrs)
    let x = bounds.width - Layout.horizontalPadding - maxW
    let y = (bounds.height - size.height) / 2
    return NSRect(x: x, y: y, width: maxW, height: size.height)
  }

  // MARK: - Click callback

  /// Called when the user clicks the status item. The owning controller
  /// sets this to handle menu presentation.
  var onClick: (() -> Void)?

  // MARK: - Init

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    guard let layer else { return }
    layer.addSublayer(inactiveBorderLayer)
    layer.addSublayer(progressArcLayer)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // MARK: - Mouse

  override func mouseDown(with event: NSEvent) {
    onClick?()
  }

  // MARK: - Sizing

  override var intrinsicContentSize: NSSize {
    let textWidth = textMaxWidth
    let width = Layout.horizontalPadding + Layout.iconSize + Layout.iconTextGap + textWidth + Layout.horizontalPadding
    return NSSize(width: width, height: Layout.height)
  }

  // MARK: - Layout

  override func layout() {
    super.layout()
    updateBorderPaths()
  }

  private func updateBorderPaths() {
    let inset = Layout.borderWidth / 2
    let rect = bounds.insetBy(dx: inset, dy: inset)
    let path = capsulePath(in: rect)
    inactiveBorderLayer.path = path
    progressArcLayer.path = path
  }

  // MARK: - Capsule Path

  /// Creates a capsule (fully rounded rect) CGPath starting at the top-center
  /// and proceeding clockwise. This allows `strokeEnd` to reveal the arc
  /// clockwise from 12 o'clock.
  private func capsulePath(in rect: NSRect) -> CGPath {
    let r = rect.height / 2
    let path = CGMutablePath()

    let minX = rect.minX
    let midX = rect.midX
    let maxX = rect.maxX
    let minY = rect.minY
    let maxY = rect.maxY

    // Start at top center
    path.move(to: CGPoint(x: midX, y: minY))

    // Right half of top edge → top-right arc center
    path.addLine(to: CGPoint(x: maxX - r, y: minY))

    // Top-right quarter circle (clockwise: -π/2 → 0)
    path.addArc(
      center: CGPoint(x: maxX - r, y: minY + r),
      radius: r,
      startAngle: -.pi / 2,
      endAngle: 0,
      clockwise: false
    )

    // Bottom-right quarter circle (clockwise: 0 → π/2)
    path.addArc(
      center: CGPoint(x: maxX - r, y: maxY - r),
      radius: r,
      startAngle: 0,
      endAngle: .pi / 2,
      clockwise: false
    )

    // Bottom edge (right→left)
    path.addLine(to: CGPoint(x: minX + r, y: maxY))

    // Bottom-left quarter circle (clockwise: π/2 → π)
    path.addArc(
      center: CGPoint(x: minX + r, y: maxY - r),
      radius: r,
      startAngle: .pi / 2,
      endAngle: .pi,
      clockwise: false
    )

    // Top-left quarter circle (clockwise: π → 3π/2 = -π/2)
    path.addArc(
      center: CGPoint(x: minX + r, y: minY + r),
      radius: r,
      startAngle: .pi,
      endAngle: -.pi / 2,
      clockwise: false
    )

    // Left half of top edge → back to top center
    path.addLine(to: CGPoint(x: midX, y: minY))
    path.closeSubpath()

    return path
  }

  // MARK: - Drawing

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    drawIcon()
    drawTimeText()
  }

  private func drawIcon() {
    guard let image = NSImage(
      systemSymbolName: "shield.slash.fill",
      accessibilityDescription: nil
    ) else { return }

    image.draw(in: iconRect)
  }

  private func drawTimeText() {
    let textColor: NSColor = isUrgent ? .systemRed : .labelColor
    let attrs: [NSAttributedString.Key: Any] = [
      .font: timeFont,
      .foregroundColor: textColor,
    ]
    (formattedTime as NSString).draw(in: textRect, withAttributes: attrs)
  }

  // MARK: - Public API

  /// Updates the view state. Call this whenever remainingSeconds or totalDuration changes.
  func update(remainingSeconds: TimeInterval, totalDuration: TimeInterval?, formattedTime: String) {
    self.remainingSeconds = remainingSeconds
    self.totalDuration = totalDuration
    self.formattedTime = formattedTime

    // Update the progress arc layer
    progressArcLayer.strokeEnd = isIndefinite ? 0 : progressFraction
    progressArcLayer.strokeColor = isUrgent
      ? NSColor.systemRed.cgColor
      : NSColor.systemOrange.cgColor

    // Redraw text/icon (color may have changed)
    needsDisplay = true
  }
}
```

- [ ] **Step 2: Build to verify the file compiles**

```bash
xcodebuild -project Holeberry.xcodeproj -scheme Holeberry -destination 'platform=macOS' build 2>&1 | tail -20
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Sources/Holeberry/App/StatusItemButton.swift
git commit -m "feat: add StatusItemButton custom view with capsule progress ring"
```

---

### Task 3: Integrate custom view into `MenuBarController`

**Files:**
- Modify: `Sources/Holeberry/App/MenuBarController.swift:99-128`

**Interfaces:**
- Consumes: `StatusItemButton` class, `TimerManager.totalDuration`
- Produces: `updateDisplay` now swaps between normal `button` and custom `statusItem.view`

- [ ] **Step 1: Add `statusItemButton` property and update `observeTimer`**

In `MenuBarController`, add a lazy property and change the `observeTimer` subscription to include `totalDuration`:

```swift
@MainActor
final class MenuBarController: NSObject {
  // ... existing properties ...

  // MARK: - Countdown view

  private lazy var statusItemButton: StatusItemButton = {
    let view = StatusItemButton()
    view.onClick = { [weak self] in
      self?.handleClick()
    }
    return view
  }()
```

- [ ] **Step 2: Replace `observeTimer()` to include `totalDuration`**

```swift
  // MARK: - Timer Observation

  private func observeTimer() {
    timerManager.$isDisabled
      .combineLatest(timerManager.$remainingSeconds, timerManager.$totalDuration)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] isDisabled, remaining, totalDuration in
        self?.updateDisplay(
          isDisabled: isDisabled,
          remaining: remaining,
          totalDuration: totalDuration
        )
      }
      .store(in: &cancellables)
  }
```

- [ ] **Step 3: Replace `updateDisplay` with the swap logic**

```swift
  private func updateDisplay(isDisabled: Bool, remaining: TimeInterval, totalDuration: TimeInterval?) {
    if isDisabled && remaining > 0 {
      // Timed countdown — use custom view
      if statusItem.view !== statusItemButton {
        statusItem.view = statusItemButton
        statusItem.button?.image = nil
        statusItem.button?.title = ""
      }
      statusItemButton.update(
        remainingSeconds: remaining,
        totalDuration: totalDuration,
        formattedTime: timerManager.formattedTime
      )
      statusItemButton.setAccessibilityLabel(
        "Pi-hole disabled, \(timerManager.formattedTime) remaining"
      )
    } else if isDisabled {
      // Indefinite — use custom view with "∞"
      if statusItem.view !== statusItemButton {
        statusItem.view = statusItemButton
        statusItem.button?.image = nil
        statusItem.button?.title = ""
      }
      statusItemButton.update(
        remainingSeconds: 0,
        totalDuration: nil,
        formattedTime: "\u{221E}"
      )
      statusItemButton.setAccessibilityLabel("Pi-hole disabled indefinitely")
    } else {
      // Blocking active — revert to normal button
      if statusItem.view != nil {
        statusItem.view = nil
      }
      guard let button = statusItem.button else { return }
      button.title = ""
      button.image = NSImage(
        systemSymbolName: "shield.fill",
        accessibilityDescription: "Pi-hole Active"
      )
      button.setAccessibilityLabel("Pi-hole blocking active")
    }
  }
```

- [ ] **Step 4: Update `handleClick` to pop up the menu when custom view is showing**

When `statusItem.view` is set (custom view active), `statusItem.button?.performClick(nil)` won't work because the button is hidden. Pop up the menu manually instead:

```swift
  @objc private func handleClick() {
    ensureCacheFresh()

    let browserTabStatus = browserUrlFetcher.resolveCurrentTabDomain()
    var browserIcon: NSImage?
    if case .url = browserTabStatus {
      browserIcon = resolveBrowserIcon()
    }
    let menu = menuBuilder.buildMenu(
      recentBlocked: recentBlockedCache,
      error: errorMessage,
      isConnected: reachability.isConnected,
      combinedStatus: statusMonitor.combinedStatus,
      connectionStatuses: statusMonitor.connectionStatuses,
      blockingStatuses: statusMonitor.blockingStatuses,
      servers: statusMonitor.servers,
      browserTabStatus: browserTabStatus,
      browserIcon: browserIcon
    )
    menu.delegate = self
    currentMenu = menu
    statusItem.menu = menu

    if let customView = statusItem.view {
      menu.popUp(
        positioning: nil,
        at: NSPoint(x: 0, y: customView.bounds.height),
        in: customView
      )
    } else {
      statusItem.button?.performClick(nil)
    }
  }
```

The existing `configureStatusItem()` method (which sets `button.action = #selector(handleClick)`) is unchanged — it handles clicks when the normal button is showing.

- [ ] **Step 5: Build to verify full integration**

```bash
xcodebuild -project Holeberry.xcodeproj -scheme Holeberry -destination 'platform=macOS' build 2>&1 | tail -20
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: Commit**

```bash
git add Sources/Holeberry/App/MenuBarController.swift
git commit -m "feat: swap menu bar status item between normal button and custom countdown ring view"
```

---

### Task 4: Verify end-to-end behavior

**Files:**
- None (verification only)

**Interfaces:**
- Consumes: all work from Tasks 1–3

- [ ] **Step 1: Clean build**

```bash
xcodebuild -project Holeberry.xcodeproj -scheme Holeberry -destination 'platform=macOS' clean build 2>&1 | grep -E 'BUILD|error:|warning:' | head -20
```

Expected: `** BUILD SUCCEEDED **`, no errors, only pre-existing warnings if any.

- [ ] **Step 2: Run existing test suite**

```bash
xcodebuild -project Holeberry.xcodeproj -scheme Holeberry -destination 'platform=macOS' test 2>&1 | tail -30
```

Expected: all existing tests pass.

- [ ] **Step 3: Manual verification checklist** (run the app and confirm)

1. **Normal state** — menu bar shows plain `shield.fill` icon, no text, no ring. ✅
2. **Disable 30s** — menu bar shows capsule with shield.slash.fill, "30s" text, and full orange arc. Text does not jump as seconds tick down. ✅
3. **Orange → red transition** — when counter drops to ≤15% (~4s for a 30s timer), arc and text turn red. ✅
4. **Arc shrinks** — arc gets shorter each second, always starts at 12 o'clock. ✅
5. **Disable indefinitely** — menu bar shows capsule with full gray border and "∞" text. ✅
6. **Re-enable** — menu bar returns to plain `shield.fill` icon. ✅
7. **App restart with active timer** — if app restarts while timer was active, it syncs from remote and resumes correctly. ✅
8. **Dark mode** — switch between light/dark mode; orange/red/gray colors adapt correctly. ✅

- [ ] **Step 4: Commit verification results**

```bash
git add -A
git commit -m "chore: verification checklist complete for countdown ring"
```
