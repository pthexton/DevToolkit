import AppKit

/// Enumerates and switches to Ghostty terminal surfaces via in-process
/// `NSAppleScript`. Verified live against a running Ghostty using its own
/// AppleScript dictionary (`sdef /Applications/Ghostty.app`): each `terminal`
/// (surface) has a stable `id`, unlike ClaudeAlerter's `TerminalFocuser`,
/// which had to match on working directory because it only ever had a cwd
/// from a hook event, never an enumerated id. Since DevToolkit enumerates
/// everything up front, the `id` can be used directly with the `focus`
/// command.
final class GhosttyProvider: WindowProvider {
    static let supportedBundleIDs: Set<String> = ["com.mitchellh.ghostty"]

    private static let bundleID = "com.mitchellh.ghostty"

    func isAvailable() -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == Self.bundleID }
    }

    func fetchItems() -> [SwitchItem] {
        guard isAvailable() else { return [] }

        // We emit the *tab* name (`name of t`) alongside the surface name.
        // Ghostty's tab title defaults to the active surface's title but
        // becomes a user-chosen string once the tab is renamed (e.g.
        // "claude-aidr"). That custom name lives only on the tab, never on the
        // terminal surface (`name of s`, which stays the process/cwd title),
        // so reading only the surface name made renamed tabs unsearchable.
        let script = """
        tell application "Ghostty"
            set output to ""
            repeat with w in windows
                repeat with t in tabs of w
                    set tabName to (name of t)
                    repeat with s in terminals of t
                        set output to output & (id of s) & "\t" & tabName & "\t" & (name of s) & "\t" & (working directory of s) & "\n"
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
            let fields = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false)
            guard fields.count == 4 else { continue }
            let surfaceID = String(fields[0])
            let tabName = String(fields[1])
            let surfaceName = String(fields[2])
            let cwd = String(fields[3])
            // Prefer the tab's title (which carries the user's custom name),
            // then the surface title, then the working directory.
            let title = !tabName.isEmpty ? tabName : (!surfaceName.isEmpty ? surfaceName : cwd)
            items.append(
                SwitchItem(
                    id: "ghostty:\(surfaceID)",
                    title: title,
                    subtitle: cwd,
                    icon: icon,
                    kind: .terminalTab,
                    activate: { Self.activateSurface(id: surfaceID) }
                )
            )
        }
        return items
    }

    private static func activateSurface(id surfaceID: String) {
        let escaped = surfaceID.replacingOccurrences(of: "\\", with: "\\\\")
                                .replacingOccurrences(of: "\"", with: "\\\"")
        // Deliberately no top-level `activate` here, unlike the other
        // providers: when the target surface lives on a different Space than
        // the current one, `activate` triggers macOS's own automatic
        // switch-to-that-Space behaviour, which races against Ghostty's own
        // `focus` command - which separately (and, it turns out,
        // independently) relocates the surface's window to whatever Space is
        // current at that instant. The two competing space-transitions
        // produced a visible glitch: the active Space would jump to the
        // window's original Space while the window itself got yanked onto
        // the Space you started from, so the switch looked like it silently
        // failed. `focus s` alone reliably activates Ghostty and reveals the
        // right surface without the second, conflicting relocation.
        let script = """
        tell application "Ghostty"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in terminals of t
                        if id of s is "\(escaped)" then
                            focus s
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
