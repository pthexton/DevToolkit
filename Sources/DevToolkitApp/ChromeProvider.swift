import AppKit

/// Enumerates and switches to Google Chrome tabs via in-process
/// `NSAppleScript`. Verified live against `sdef "/Applications/Google
/// Chrome.app"`: unlike Safari, Chrome tabs do have a stable `id`, but there
/// is still no "select tab by id" command - only a settable `active tab
/// index` on the window - so switching re-derives the tab's index at
/// activation time, same tradeoff as Safari.
final class ChromeProvider: WindowProvider {
    static let supportedBundleIDs: Set<String> = ["com.google.Chrome"]

    private static let bundleID = "com.google.Chrome"

    func isAvailable() -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == Self.bundleID }
    }

    func fetchItems() -> [SwitchItem] {
        guard isAvailable() else { return [] }

        // Chrome tabs have no "index" property of their own, so the index is
        // tracked manually while walking each window's tab list.
        let script = """
        tell application "Google Chrome"
            set output to ""
            repeat with w in windows
                set winID to (id of w) as string
                set tabIdx to 0
                repeat with t in tabs of w
                    set tabIdx to tabIdx + 1
                    set output to output & winID & "\t" & tabIdx & "\t" & (title of t) & "\t" & (URL of t) & "\n"
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
            let title = String(fields[2])
            let url = String(fields[3])
            items.append(
                SwitchItem(
                    id: "chrome:\(windowID):\(tabIndex)",
                    title: title.isEmpty ? url : title,
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
        tell application "Google Chrome"
            activate
            set active tab index of window id \(windowID) to \(tabIndex)
            set index of window id \(windowID) to 1
        end tell
        """
        AppleScriptRunner.runAsync(script)
    }
}
