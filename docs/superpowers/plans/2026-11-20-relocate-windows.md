# Relocate Windows Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A "Relocate" menu bar submenu that lists scriptable running apps and, on click, moves all their windows onto the display under the mouse pointer.

**Architecture:** A pure geometry type (`WindowGeometry`) converts between NSScreen and Apple Event coordinates and computes the fitted bounds. `WindowRelocator` discovers candidate apps from `Info.plist` scripting keys and drives Apple Events through the existing in-process `AppleScriptRunner`. A small SwiftUI view in `DevToolkitApp.swift` renders the submenu.

**Tech Stack:** Swift 5.9, SwiftUI `MenuBarExtra`, AppKit, XCTest. No Accessibility.

**Spec:** `docs/superpowers/specs/2026-11-20-relocate-windows-design.md`

## Global Constraints

- No Accessibility APIs; Apple Events automation only.
- Discovery must never send events to apps.
- `AppleScriptRunner.runAndReturnString` blocks: call it off the main thread.
- No emdashes in code, comments or commit messages.
- Commit trailer: `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`.
- Run tests with `swift test`.

## Review Focus

- Window larger than the target visible frame: shrinks to the visible frame (test in Task 1).
- Window already inside the target screen: left untouched, no event sent (Task 1).
- Window straddling two screens: counts as not inside, gets moved (Task 1).
- Target screen with a negative or non-zero origin (built-in at x 2560, y 323 in a bottom-left system): conversion correct (Task 1).
- App that errors or has no `bounds`: skipped and logged, menu still works (Task 2).

---

### Task 1: WindowGeometry (pure math)

**Files:**
- Create: `Sources/DevToolkitApp/WindowGeometry.swift`
- Test: `Tests/DevToolkitAppTests/WindowGeometryTests.swift`

**Interfaces:**
- Produces:
  - `struct ScreenRects { let primaryHeight: CGFloat; let targetVisibleFrame: CGRect }` (both in NSScreen bottom-left coordinates; `primaryHeight` is the height of the primary screen, `NSScreen.screens[0].frame.height`).
  - `enum WindowGeometry`
    - `static func targetBounds(for window: CGRect, in screens: ScreenRects) -> CGRect?` where `window` is in top-left Apple Event coordinates (left, top, width, height); returns nil when the window already lies fully inside the target visible frame, otherwise the fitted rect, also top-left Apple Event coordinates.
    - `static func appleEventBounds(_ rect: CGRect) -> [Int]` returning `[left, top, right, bottom]`.
    - `static func rect(fromAppleEventBounds b: [Int]) -> CGRect?` returning nil unless `b.count == 4`.

- [ ] **Step 1: Write failing tests** in `WindowGeometryTests.swift`, using the real layout from this machine: primary 2560x1440 at origin (0,0); built-in visible frame `CGRect(x: 2560, y: 323, width: 1728, height: 1085)`, `primaryHeight: 1440`. Tests:
  - `testWindowOnOtherScreenIsMovedKeepingSize`: window `CGRect(x: 100, y: 100, width: 900, height: 652)` yields a rect of the same size lying inside the visible frame (in top-left terms the visible frame is x 2560...4288, y 32...1117).
  - `testOversizedWindowShrinksToVisibleFrame`: window 2000x1300 yields exactly `CGRect(x: 2560, y: 32, width: 1728, height: 1085)`.
  - `testWindowAlreadyInsideReturnsNil`: window `CGRect(x: 2700, y: 100, width: 800, height: 600)` returns nil.
  - `testStraddlingWindowIsMoved`: window `CGRect(x: 2000, y: 100, width: 1200, height: 600)` returns a rect fully inside the visible frame.
  - `testAppleEventBoundsRoundTrip`: `appleEventBounds(CGRect(x: 10, y: 20, width: 30, height: 40)) == [10, 20, 40, 60]` and `rect(fromAppleEventBounds: [10, 20, 40, 60]) == CGRect(x: 10, y: 20, width: 30, height: 40)`; `rect(fromAppleEventBounds: [1, 2, 3])` is nil.
- [ ] **Step 2: Run** `swift test --filter WindowGeometryTests`; expected: FAIL (types not defined).
- [ ] **Step 3: Implement** the three functions. Convert the target visible frame to top-left coordinates via `top = primaryHeight - visible.maxY`; clamp the window size to the visible size; keep the window's offset from its own top-left where it still fits, otherwise clamp the origin so the rect lies inside the visible frame.
- [ ] **Step 4: Run** `swift test --filter WindowGeometryTests`; expected: PASS.
- [ ] **Step 5: Commit** `feat: add window geometry for relocating windows`.

### Task 2: WindowRelocator (discovery and Apple Events)

**Files:**
- Create: `Sources/DevToolkitApp/WindowRelocator.swift`
- Test: `Tests/DevToolkitAppTests/WindowRelocatorTests.swift`

**Interfaces:**
- Consumes: `WindowGeometry`, `ScreenRects` (Task 1); `AppleScriptRunner.runAndReturnString(_:)`.
- Produces:
  - `struct RelocatableApp: Identifiable { let id: String /* bundle id */; let name: String; let icon: NSImage?; let pid: pid_t }`
  - `enum WindowRelocator`
    - `static func isScriptable(infoDictionary: [String: Any]?) -> Bool`: true when `NSAppleScriptEnabled` is `true`, `1`, or the string `"YES"`/`"Yes"` (case-insensitive), or `OSAScriptingDefinition` is a non-empty string.
    - `static func relocatableApps() -> [RelocatableApp]`: running apps with `activationPolicy == .regular`, not DevToolkit itself, with a bundle id, whose bundle `infoDictionary` satisfies `isScriptable`; sorted by name.
    - `static func activeScreenRects() -> ScreenRects?`: target is the `NSScreen` whose `frame` contains `NSEvent.mouseLocation`, falling back to `NSScreen.main`; `primaryHeight` from `NSScreen.screens[0].frame.height`.
    - `static func relocate(_ app: RelocatableApp)`: runs on a background queue.

- [ ] **Step 1: Write failing tests** for `isScriptable`: `["NSAppleScriptEnabled": true]` true; `["NSAppleScriptEnabled": "Yes"]` true (Safari's real value); `["OSAScriptingDefinition": "UTM.sdef"]` true; `[:]` false; `nil` false; `["NSAppleScriptEnabled": false]` false.
- [ ] **Step 2: Run** `swift test --filter WindowRelocatorTests`; expected: FAIL.
- [ ] **Step 3: Implement `isScriptable`, `relocatableApps`, `activeScreenRects`**, then `relocate`: for the app, call `AppleScriptRunner.runAndReturnString` with `tell application id "<bundle id>" to get bounds of every window` returning one tab-separated line per window (use a repeat loop and `(bounds of w)` joined with commas; parse with `WindowGeometry.rect(fromAppleEventBounds:)`); for each window whose `targetBounds` is non-nil, run `tell application id "<bundle id>" to set bounds of window <i> to {l, t, r, b}`. Read all bounds before moving any, so index shifts cannot misapply. If the first script returns nil (permission denied, no bounds), `Logger.error` with the bundle id and return.
- [ ] **Step 4: Run** `swift test --filter WindowRelocatorTests`; expected: PASS.
- [ ] **Step 5: Commit** `feat: discover scriptable apps and relocate their windows`.

### Task 3: Relocate submenu and manual verification

**Files:**
- Modify: `Sources/DevToolkitApp/DevToolkitApp.swift` (menu body at lines 12-24; add a private `RelocateMenu` view beside `LitraGlowMenu`)

**Interfaces:**
- Consumes: `WindowRelocator.relocatableApps()`, `WindowRelocator.relocate(_:)`, `RelocatableApp`.

- [ ] **Step 1: Add `private struct RelocateMenu: View`** rendering `Menu("Relocate") { ... }` with one `Button(app.name)` per app (with the app icon scaled to 16x16 as the label image when present) calling `WindowRelocator.relocate(app)`; when the list is empty show a disabled `Text("No scriptable apps running")`. The list is recomputed each time the menu body is evaluated, using `.onAppear`-independent computation (call `relocatableApps()` inside the `Menu` builder).
- [ ] **Step 2: Insert `RelocateMenu()` and a `Divider()`** after `SteelSeriesClockToggle` and before `LitraGlowMenu`.
- [ ] **Step 3: Run** `swift build`; expected: succeeds. Run `swift test`; expected: all pass.
- [ ] **Step 4: Manual verification** with `./build.sh` (check its output for the app path) and launch: with UTM or Safari windows on the external display, open the menu, choose Relocate, then UTM; accept the automation prompt; confirm the windows land on the display under the pointer. Confirm Rockit does not appear.
- [ ] **Step 5: Commit** `feat: add Relocate submenu to the menu bar`.
