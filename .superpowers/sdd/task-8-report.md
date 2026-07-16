# Task 8 — Wire AppFocusMonitor and BrowserTabCoordinator in HoleberryApp

**Status:** DONE  
**Commit:** `1b565b9` — `feat: wire AppFocusMonitor and BrowserTabCoordinator in HoleberryApp`

## Changes

**File:** `Sources/Holeberry/App/HoleberryApp.swift`

1. **Added `AppFocusMonitor` instance** (line 53): `let appFocusMonitor = AppFocusMonitor()`
2. **Preserved `BrowserUrlFetcher` instance** (line 54): `let browserUrlFetcher = BrowserUrlFetcher()` — still needed by `BrowserTabCoordinator`
3. **Added `BrowserTabCoordinator` instance** (lines 55–58): Created with `appFocusMonitor` and `browserUrlFetcher`
4. **Updated `MenuBarController` constructor call** (line 65): Changed `browserUrlFetcher: browserUrlFetcher` → `browserTabCoordinator: browserTabCoordinator`
5. **Updated `ShortcutController` constructor call** (line 71): Changed `browserUrlFetcher: browserUrlFetcher` → `browserTabCoordinator: browserTabCoordinator`

## Verification

- `xcodebuild clean build` — **BUILD SUCCEEDED** (Release configuration, no errors)
- No remaining errors referencing `BrowserUrlFetcher` in either `MenuBarController` or `ShortcutController` init calls.
- All tasks from Task 1 through Task 8 now compile cleanly with no errors.

## Review

**Task 7 Review** also written to `.superpowers/sdd/task-7-review.md`:
- ✅ Fully spec-compliant
- ✅ No regressions
- ✅ Ready to proceed
