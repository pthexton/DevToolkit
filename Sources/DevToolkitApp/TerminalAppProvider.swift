import AppKit

/// Enumerates and switches to Terminal.app tabs via in-process
/// `NSAppleScript`, the same recipe ClaudeAlerter's `TerminalFocuser` uses in
/// production: a tab is addressed by its `tty` property, which Terminal.app's
/// dictionary guarantees is unique per tab (confirmed via `sdef
/// "/System/Applications/Utilities/Terminal.app"`). Terminal.app has no
/// per-tab title unless the user sets a custom one, so the displayed title
/// falls back to the deepest running process name (e.g. "vim" rather than
/// the parent shell).
final class TerminalAppProvider: WindowProvider {
    static let supportedBundleIDs: Set<String> = ["com.apple.Terminal"]

    private static let bundleID = "com.apple.Terminal"

    func isAvailable() -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == Self.bundleID }
    }

    func fetchItems() -> [SwitchItem] {
        guard isAvailable() else { return [] }

        let script = """
        tell application "Terminal"
            set output to ""
            repeat with w in windows
                repeat with t in tabs of w
                    set displayTitle to ""
                    try
                        if title displays custom title of t then set displayTitle to custom title of t
                    end try
                    if displayTitle is "" then
                        try
                            set procs to processes of t
                            set displayTitle to item (count of procs) of procs
                        end try
                    end if
                    set output to output & (tty of t) & "\t" & displayTitle & "\n"
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
            let fields = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2 else { continue }
            let tty = String(fields[0])
            let title = String(fields[1])
            items.append(
                SwitchItem(
                    id: "terminal:\(tty)",
                    title: title.isEmpty ? tty : title,
                    subtitle: tty,
                    icon: icon,
                    kind: .terminalTab,
                    activate: { Self.activateTab(tty: tty) }
                )
            )
        }
        return items
    }

    private static func activateTab(tty: String) {
        let escaped = tty.replacingOccurrences(of: "\\", with: "\\\\")
                          .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Terminal"
            activate
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "\(escaped)" then
                        set frontmost of w to true
                        set selected tab of w to t
                        return
                    end if
                end repeat
            end repeat
        end tell
        """
        AppleScriptRunner.runAsync(script)
    }
}
