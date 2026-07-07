import AppKit

/// Enumerates and switches to Safari tabs via in-process `NSAppleScript`
/// (never `osascript`, never Accessibility) - the same model ClaudeAlerter
/// uses for terminal focusing.
///
/// Safari's current scripting dictionary (verified via `sdef
/// /Applications/Safari.app`) gives tabs no `id` property, only `name`,
/// `URL`, and `index`; only `window` (from the standard suite) has a stable
/// `id`. So a tab is addressed as `tab <index> of window id <windowID>` -
/// stable enough for the sub-second gap between listing and selecting.
final class SafariProvider: WindowProvider {
    static let supportedBundleIDs: Set<String> = ["com.apple.Safari"]

    private static let bundleID = "com.apple.Safari"

    func isAvailable() -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == Self.bundleID }
    }

    func fetchItems() -> [SwitchItem] {
        guard isAvailable() else { return [] }

        // One AppleScript call enumerates every window/tab into a flat,
        // tab/newline-delimited string - far simpler and more robust than
        // walking nested NSAppleEventDescriptor lists.
        let script = """
        tell application "Safari"
            set output to ""
            repeat with w in windows
                set winID to (id of w) as string
                repeat with t in tabs of w
                    set output to output & winID & "\t" & ((index of t) as string) & "\t" & (name of t) & "\t" & (URL of t) & "\n"
                end repeat
            end repeat
            return output
        end tell
        """
        guard let raw = AppleScriptRunner.runAndReturnString(script), !raw.isEmpty else { return [] }

        let icon = NSWorkspace.shared.runningApplications
            .first { $0.bundleIdentifier == Self.bundleID }?.icon

        var items: [SwitchItem] = []
        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false)
            guard fields.count == 4,
                  let windowID = Int(fields[0]),
                  let tabIndex = Int(fields[1]) else { continue }
            let name = String(fields[2])
            let url = String(fields[3])
            items.append(
                SwitchItem(
                    id: "safari:\(windowID):\(tabIndex)",
                    title: name.isEmpty ? url : name,
                    subtitle: url,
                    icon: icon,
                    kind: .browserTab,
                    activate: { Self.activateTab(windowID: windowID, tabIndex: tabIndex) }
                )
            )
        }
        return items
    }

    private static func activateTab(windowID: Int, tabIndex: Int) {
        let script = """
        tell application "Safari"
            activate
            set current tab of window id \(windowID) to tab \(tabIndex) of window id \(windowID)
            set index of window id \(windowID) to 1
        end tell
        """
        AppleScriptRunner.runAsync(script)
    }
}
