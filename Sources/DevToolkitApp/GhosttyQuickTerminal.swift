import AppKit

/// Proxies Ghostty's quake-mode "quick terminal" toggle via its own
/// AppleScript `perform action` command - entirely through the same Apple
/// Events automation permission the rest of DevToolkit already uses.
///
/// Ghostty's own `global:` keybind mechanism needs Accessibility permission
/// (it's implemented via a system-wide keystroke-observing event tap, unlike
/// DevToolkit's own permission-free Carbon hotkey). This sidesteps that
/// entirely: DevToolkit owns the global hotkey, and on trigger just asks
/// Ghostty to perform the action - confirmed live via
/// `perform action "toggle_quick_terminal" on terminal 1`.
enum GhosttyQuickTerminal {
    private static let bundleID = "com.mitchellh.ghostty"

    static func toggle() {
        guard NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == bundleID }) else {
            return
        }
        // `perform action` requires a target terminal even for an app-wide
        // action like this; falls back to a plain activate if none exist
        // (e.g. Ghostty running with zero open windows).
        let script = """
        tell application "Ghostty"
            try
                perform action "toggle_quick_terminal" on terminal 1
            on error
                activate
            end try
        end tell
        """
        AppleScriptRunner.runAsync(script)
    }
}
