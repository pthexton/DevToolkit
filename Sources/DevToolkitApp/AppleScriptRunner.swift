import AppKit

/// Small shared wrapper around in-process `NSAppleScript` execution - the
/// same mechanism ClaudeAlerter uses for terminal focusing, never
/// `osascript` shell-out, never Accessibility.
enum AppleScriptRunner {
    /// Runs `source` synchronously and returns its string result, or nil on
    /// error. Blocking - always call this off the main thread.
    static func runAndReturnString(_ source: String) -> String? {
        guard let script = NSAppleScript(source: source) else { return nil }
        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)
        guard errorInfo == nil else { return nil }
        return result.stringValue
    }

    /// Fire-and-forget: runs `source` on a background queue, ignoring the
    /// result. Safe to call from the main thread.
    static func runAsync(_ source: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            var errorInfo: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&errorInfo)
        }
    }
}
