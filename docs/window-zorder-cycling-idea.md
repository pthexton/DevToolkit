# Idea: cycle windows by real z-order (shelved)

## The idea

Cmd+Tab cycles *apps*, not windows - if you have two Ghostty windows with a
Screen Sharing window sandwiched between them in real stacking order, Cmd+Tab
collapses both Ghostty windows into one app slot and you lose that ordering
entirely.

The idea was: while the DevToolkit overlay is open (Option+Space), let Tab /
Shift+Tab cycle through windows in their *actual* on-screen z-order, scoped to
the current virtual desktop (Space) - e.g. `[Ghostty A] -> [Screen Sharing] ->
[Ghostty B] -> ...` - and raise the exact window you land on, not just its
app.

## What's actually possible without Accessibility

DevToolkit has a hard rule against using the Accessibility API (IT makes
that permission painful to roll out). Investigated what's achievable with
public, no-extra-permission APIs instead:

- `CGWindowListCopyWindowInfo(.optionOnScreenOnly, ...)` returns every
  on-screen window already in front-to-back z-order, with owning app and
  on-screen bounds - **no permission required at all**.
- `.optionOnScreenOnly` already scopes correctly to just the *current* Space:
  verified live that windows sitting on other Spaces (Safari, Chrome) were
  simply absent from the list while windows on the current Space (Ghostty,
  Screen Sharing, Activity Monitor) were present.
- The one thing that *does* need extra permission (Screen Recording, a
  separate and more sensitive bucket than the Apple Events permission
  DevToolkit already uses) is the window's title text. Everything else -
  owner, position, order - is free.

So reading the z-order list is entirely solvable within the existing "no
Accessibility" constraint.

## The blocker: raising an exact window, precisely, for every app

Reading the list is only half the problem - DevToolkit also needs to raise
the *specific* window you land on, not just bring its app forward in general
(which just restores whatever window that app itself last considered
current).

Verified live, by cross-referencing each app's own AppleScript-reported
window `id` against the CGWindowNumber for the same on-screen window:

| App | Window `id` via AppleScript | Same as CGWindowNumber? |
|---|---|---|
| Safari | integer, standard Cocoa `uniqueID` | **Yes** - confirmed live |
| Google Chrome | integer, standard Cocoa `uniqueID` | **Yes** - confirmed live |
| iTerm2 | integer, standard Cocoa `uniqueID` | **Yes** - iTerm2's own dictionary comments confirm this, calling it out as usable with `screencapture -l` |
| Terminal.app | integer, standard Cocoa `uniqueID` | **Yes** - same standard suite as Safari/Chrome |
| **Ghostty** | custom opaque string (e.g. `tab-group-892bf0e60`) | **No** |

For Safari, Chrome, iTerm2, and Terminal.app, a CGWindowNumber from the
z-order list maps directly and exactly onto that app's own AppleScript window
object - so DevToolkit could raise precisely the right window every time,
with no ambiguity.

**Ghostty breaks this.** Its window `id` is an internal identifier that has
no relationship to the CGWindowNumber, and Ghostty's AppleScript window class
exposes no `bounds`/position property either, so there is no way - short of
Accessibility - to work out which of Ghostty's own AppleScript window objects
corresponds to a given entry in the system z-order list. The only thing
possible for a Ghostty window (and for any other generic, non-scriptable app,
e.g. Screen Sharing) is `NSRunningApplication.activate()` on the whole app,
which brings forward whichever window *Ghostty itself* thinks is current -
not necessarily the one you actually tabbed to.

Since the original motivating scenario was disambiguating between two
specific Ghostty windows, this gap defeats the point for the case that
mattered most, so the feature is shelved rather than shipped half-working.

## If revisited later

A version scoped to just Safari / Chrome / iTerm2 / Terminal.app (with
Ghostty and everything else falling back to coarse whole-app activation, the
same as the existing generic app fallback elsewhere in DevToolkit) is still
a real, working QoL improvement - it just isn't the fully general "any two
windows, any app" switcher originally pictured. Worth reconsidering if a
future Ghostty release exposes window bounds or a windowNumber-based id via
its scripting dictionary.
