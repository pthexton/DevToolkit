import AppKit

/// Enumerates and switches to iTerm2 sessions via in-process `NSAppleScript`,
/// the same recipe ClaudeAlerter's `TerminalFocuser` uses in production: a
/// session is addressed by its stable "unique ID", found by walking
/// windows -> tabs -> sessions. Verified live against a running iTerm2.
///
/// iTerm2's `variable named "session.path"` command (which would give a
/// friendlier cwd-based subtitle) throws "Access not allowed" without extra
/// user configuration, so the session's `name` (its tab/session title) and
/// `tty` are used instead.
final class ITerm2Provider: WindowProvider {
    static let supportedBundleIDs: Set<String> = ["com.googlecode.iterm2"]

    private static let bundleID = "com.googlecode.iterm2"

    func isAvailable() -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == Self.bundleID }
    }

    func fetchItems() -> [SwitchItem] {
        guard isAvailable() else { return [] }

        let script = """
        tell application "iTerm2"
            set output to ""
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        set output to output & (unique ID of s) & "\t" & (name of s) & "\t" & (tty of s) & "\n"
                    end repeat
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
            let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3 else { continue }
            let sessionID = String(fields[0])
            let name = String(fields[1])
            let tty = String(fields[2])
            items.append(
                SwitchItem(
                    id: "iterm2:\(sessionID)",
                    title: name.isEmpty ? tty : name,
                    subtitle: tty,
                    icon: icon,
                    kind: .terminalTab,
                    activate: { Self.activateSession(id: sessionID) }
                )
            )
        }
        return items
    }

    private static func activateSession(id sessionID: String) {
        let escaped = sessionID.replacingOccurrences(of: "\\", with: "\\\\")
                                .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "iTerm2"
            activate
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if unique id of s is "\(escaped)" then
                            tell w to select
                            set current tab of w to t
                            set current session of t to s
                            return
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        """
        AppleScriptRunner.runAsync(script)
    }
}
