# Relocate windows to the active display (design)

## Intent
When the external monitor is switched to another input (for example it is doing
main-pc duty), macOS keeps windows on it and they become unreachable. The menu
bar needs a one-click way to pull an app's windows onto the display being used.

## Goals
- A "Relocate" submenu in the DevToolkit menu bar item, built dynamically from
  running apps (no hard-coded list).
- Clicking an app moves all of that app's windows onto the active display.
- No Accessibility permission. Only the Apple Events automation permission the
  app already uses.

## Non-goals
- Rockit (no scripting support; internal tool, to be addressed separately).
- Moving windows between Spaces, or windows in native full-screen.
- Restoring windows to their previous positions.
- Listing individual windows in the menu.

## Anti-goals
- Never prompt for or depend on Accessibility.
- Never quit, close, resize beyond what is needed to fit, or otherwise alter apps.

## Constraints
- Apple Events automation prompt appears per target app on first use.
- Discovery must not send events to apps (that would prompt for every app each
  time the menu opens).

## Approaches considered
1. Apple Events per app, discovery from Info.plist (chosen). Covers UTM, Safari,
   Chrome, Terminal, iTerm2, Finder and similar. Rockit is excluded.
2. Accessibility (AXUIElement). Covers everything, but violates the standing
   no-Accessibility constraint.
3. Display-level trick (disable or mirror the dead display). Not per-app, uses
   private APIs, unverified.

## Design
- **Discovery:** running apps with `activationPolicy == .regular`, excluding
  DevToolkit itself, whose bundle `Info.plist` has `NSAppleScriptEnabled` true or
  an `OSAScriptingDefinition`. Parsing sdef for `bounds` was tested and rejected:
  UTM inherits the standard window class without declaring it.
- **Active display:** the `NSScreen` containing the mouse pointer when the item
  is clicked.
- **Moving:** read `bounds of every window` via the app's Apple Events, convert
  coordinates (NSScreen is bottom-left origin; Apple Events use top-left origin
  from the primary screen), and for each window not already inside the target
  screen's visible frame set `bounds` so it fits: keep size when it fits,
  otherwise shrink to the visible frame, and keep the offset where possible.
- **Failures:** apps that error (permission denied, no `bounds`) are skipped and
  logged; nothing is shown to the user beyond the menu staying usable.
- **Code:** new `WindowRelocator.swift` (pure fit/coordinate math plus the Apple
  Events calls), a `Relocate` submenu view in `DevToolkitApp.swift`, unit tests
  for the math.

## Left to the builder
- Exact Apple Events mechanism (`NSAppleEventDescriptor` events or in-process
  `NSAppleScript`, matching existing `AppleScriptRunner`).
- Running off the main thread, as `AppleScriptRunner` requires.
