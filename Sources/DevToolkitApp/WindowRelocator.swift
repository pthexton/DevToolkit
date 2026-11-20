import AppKit
import OSLog

private let log = Logger(subsystem: "com.beyondtrust.devtoolkit", category: "relocate")

struct RelocatableApp: Identifiable {
    let id: String // bundle id
    let name: String
    let icon: NSImage?
    let pid: pid_t
}

/// Pulls an app's windows onto the display under the mouse pointer using the
/// app's own scripting interface (Apple Events), never Accessibility. Apps
/// that publish no scripting support (for example Rockit) simply don't
/// qualify and are omitted from the menu.
enum WindowRelocator {
    /// Discovery reads only the app's `Info.plist`; it never sends an event,
    /// because that would raise an automation prompt for every app each time
    /// the menu opens. (Parsing the sdef for `bounds` was tried and rejected:
    /// UTM inherits the standard window class without declaring it.)
    static func isScriptable(infoDictionary: [String: Any]?) -> Bool {
        guard let info = infoDictionary else { return false }
        switch info["NSAppleScriptEnabled"] {
        case let flag as Bool where flag: return true
        case let flag as NSNumber where flag.boolValue: return true
        case let text as String where ["yes", "true", "1"].contains(text.lowercased()): return true
        default: break
        }
        if let sdef = info["OSAScriptingDefinition"] as? String, !sdef.isEmpty { return true }
        return false
    }

    static func relocatableApps() -> [RelocatableApp] {
        let selfBundleID = Bundle.main.bundleIdentifier
        return NSWorkspace.shared.runningApplications.compactMap { app -> RelocatableApp? in
            guard app.activationPolicy == .regular,
                  let bundleID = app.bundleIdentifier, bundleID != selfBundleID,
                  let url = app.bundleURL,
                  isScriptable(infoDictionary: Bundle(url: url)?.infoDictionary) else { return nil }
            return RelocatableApp(id: bundleID,
                                  name: app.localizedName ?? bundleID,
                                  icon: app.icon,
                                  pid: app.processIdentifier)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The screen under the mouse pointer, falling back to the main screen.
    static func activeScreenRects() -> ScreenRects? {
        let screens = NSScreen.screens
        guard let primary = screens.first else { return nil }
        let mouse = NSEvent.mouseLocation
        guard let target = screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { return nil }
        return ScreenRects(primaryHeight: primary.frame.height, targetVisibleFrame: target.visibleFrame)
    }

    /// One line per window: `left,top,right,bottom`. A malformed line becomes
    /// nil so the array index still equals the window's position.
    static func parseBoundsList(_ raw: String) -> [CGRect?] {
        raw.split(separator: "\n", omittingEmptySubsequences: true).map { line in
            let values = line.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            return WindowGeometry.rect(fromAppleEventBounds: values.map { Int($0) })
        }
    }

    /// Fire-and-forget. Reads every window's bounds first, then moves the
    /// ones not already on the active display.
    static func relocate(_ app: RelocatableApp) {
        guard let screens = activeScreenRects() else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let readScript = """
            tell application id "\(app.id)"
                set out to ""
                repeat with w in windows
                    set b to bounds of w
                    set out to out & (item 1 of b as integer) & "," & (item 2 of b as integer) & "," & (item 3 of b as integer) & "," & (item 4 of b as integer) & linefeed
                end repeat
                return out
            end tell
            """
            guard let raw = AppleScriptRunner.runAndReturnString(readScript) else {
                log.error("Could not read window bounds for \(app.id, privacy: .public) (permission denied or no bounds support)")
                return
            }
            for (offset, window) in parseBoundsList(raw).enumerated() {
                guard let window, let target = WindowGeometry.targetBounds(for: window, in: screens) else { continue }
                let b = WindowGeometry.appleEventBounds(target)
                let moveScript = """
                tell application id "\(app.id)" to set bounds of window \(offset + 1) to {\(b[0]), \(b[1]), \(b[2]), \(b[3])}
                """
                if AppleScriptRunner.runAndReturnString(moveScript) == nil {
                    log.error("Could not move window \(offset + 1) of \(app.id, privacy: .public)")
                }
            }
        }
    }
}
