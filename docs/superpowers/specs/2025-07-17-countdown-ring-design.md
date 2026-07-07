# Countdown Ring Progress Indicator — Menu Bar Status Item

**Date:** 2025-07-17  
**Status:** design

## Problem

When Pi-hole blocking is temporarily disabled with a countdown timer, the macOS menu bar shows a `shield.slash.fill` icon and a time label (e.g. `"30s"`, `"1:30"`). Two issues:

1. **Text jumping** — proportional font digits have different advance widths (`"30s"` ≠ `"29s"`), so the menu bar item shifts left/right every second.
2. **No visual progress** — the user must read the number to know how much time remains. No at-a-glance indication.

Additionally, the spec calls for a countdown ring that communicates remaining time visually — a colored arc wrapping the status item that shrinks clockwise over time.

## Design

### Architecture

```
MenuBarController
  │
  ├─ NORMAL (blocking active, no timer)
  │     statusItem.button.image = shield.fill
  │     statusItem.button.title = ""
  │     statusItem.view = nil          // use default NSStatusBarButton
  │
  └─ COUNTDOWN (blocking disabled with timed duration)
        statusItem.view = statusItemButton (custom NSView)
          ├─ draw(_:) → capsule border + progress arc
          ├─ draws shield.slash.fill SF Symbol
          └─ draws monospaced time text

  INDEFINITE (blocking disabled, no expiry)
        Same custom view, but draws full gray border (no colored arc),
        shows "∞" as the time text.
```

- **New file:** `Sources/Holeberry/App/StatusItemButton.swift` — custom `NSView` subclass
- **Modified:** `MenuBarController.swift` — swap between normal button and custom view
- **Minor change:** `TimerManager.swift` — expose `totalDuration: TimeInterval?` for progress fraction

### Visual behavior by state

| State | View | Icon | Ring | Text |
|-------|------|------|------|------|
| Blocking active | Standard `button.image` | `shield.fill` | None | None |
| Countdown (>15%) | Custom view | `shield.slash.fill` | Orange arc, shrinking CW | `labelColor`, monospaced |
| Countdown (≤15%) | Custom view | `shield.slash.fill` | Red arc | `systemRed`, monospaced |
| Indefinite (∞) | Custom view | `shield.slash.fill` | Full gray border | `labelColor`, "∞" |

### Layout

```
  ┌─────────────────────────┐
  │  🛡  30s                │   ← capsule border, 2pt, fully rounded ends
  └─────────────────────────┘
       ↑                ↑
   shield icon     monospaced time
   (16pt, fixed)   (.monospacedDigitSystemFont, 12pt, bold)
```

- **Capsule:** transparent fill (menu bar background shows through), 2pt border stroke
- **Fixed width:** intrinsic content size based on widest plausible string (`"88:88"`) — never resizes
- **Icon:** 8pt left padding, vertically centered
- **Text:** right-aligned, 8pt right padding, 8pt gap from icon
- **Height:** matches standard menu bar item height (~22pt)

### Colors (system semantic — adapt to dark/light mode)

| Element | Color |
|---------|-------|
| Progress arc (>15% remaining) | `NSColor.systemOrange` |
| Progress arc (≤15% remaining) | `NSColor.systemRed` |
| Inactive border (both states) | `NSColor.separatorColor` |
| Time text (normal, >15%) | `NSColor.labelColor` |
| Time text (urgent, ≤15%) | `NSColor.systemRed` |

### Progress ring drawing

- Arc starts at 12 o'clock (top center of the capsule) and shrinks clockwise
- Fraction: `max(0, remainingSeconds / totalDuration)`
- The arc is drawn as a stroked `NSBezierPath` segment over the full inactive border
- Inactive portion of the border remains `separatorColor`
- Arc length is proportional — 100% = full perimeter, 50% = right half, 5% = tiny top segment
- Arc is always the full 2pt thickness, never thins

### Text jumping prevention (two safeguards)

1. **`.monospacedDigitSystemFont(ofSize:weight:)`** — Apple's monospaced digit variant. Every digit (0–9) has identical advance width. `"30s"` and `"29s"` render at the exact same pixel width.
2. **Fixed intrinsic width** — the `NSView` reports a fixed `intrinsicContentSize` matching the widest plausible string (e.g., `"88:88"`). The capsule border and text layout reference this fixed size.

### Animations

| Animation | Method | Duration |
|-----------|--------|----------|
| Arc length shrinking | `CADisplayLink` → `needsDisplay = true` | Continuous (60fps interpolation between second ticks) |
| Color transition (orange → red) | `NSView.animator()` or color interpolation in draw | ~200ms |
| Text color (white → red) | `NSView.animator()` | ~200ms |
| View swap (button ↔ custom view) | Direct assignment, no animation needed | Instant |

### View lifecycle

```
Timer starts
  → statusItem.view = customView  (or update model on existing view)
  → CADisplayLink starts
  → draw updates each frame

Timer ticks / expires
  → remainingSeconds → 0
  → cancelDisable() fires
  → statusItem.view = nil
  → falls back to statusItem.button (plain shield.fill)

Re-enable manually
  → same as timer expiry path
```

### Files changed

| File | Change |
|------|--------|
| `Sources/Holeberry/App/StatusItemButton.swift` | **New** — custom NSView with draw(_:) |
| `Sources/Holeberry/App/MenuBarController.swift` | Replace `updateDisplay()` logic; add swap between button and custom view |
| `Sources/Holeberry/Services/TimerManager.swift` | Expose `totalDuration: TimeInterval?` property |

### Out of scope

- No change to `MenuBuilder.swift` — menu content is unrelated to the status item display
- No change to indefinite-disabled behavior beyond the status item (the "∞" text + gray border)
- No change to the settings UI
- No accessibility changes beyond what `NSStatusBarButton` already provides (the custom view inherits basic accessibility via `NSView` — full accessibility audit deferred)
