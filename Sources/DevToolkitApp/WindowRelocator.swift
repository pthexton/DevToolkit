import AppKit
import OSLog

private let log = Logger(subsystem: "com.beyondtrust.devtoolkit", category: "relocate")

struct RelocatableApp: Identifiable {
    let id: String // bundle id
    let name: String
    let icon: NSImage?
    /// Every running process sharing this bundle id (each `rockit run` is its own process).
    let pids: [pid_t]
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
    let candidates = NSWorkspace.shared.runningApplications.compactMap { app -> (id: String, name: String, icon: NSImage?, pid: pid_t)? in
        guard app.activationPolicy == .regular,
              let bundleID = app.bundleIdentifier, bundleID != selfBundleID,
              let url = app.bundleURL,
              isScriptable(infoDictionary: Bundle(url: url)?.infoDictionary) else { return nil }
        return (bundleID, app.localizedName ?? bundleID, app.icon, app.processIdentifier)
    }
    return grouped(candidates)
}

/// One entry per bundle id, carrying every pid, sorted by name.
static func grouped(_ candidates: [(id: String, name: String, icon: NSImage?, pid: pid_t)]) -> [RelocatableApp] {
    Dictionary(grouping: candidates, by: \.id).map { id, group in
        RelocatableApp(id: id, name: group[0].name, icon: group[0].icon, pids: group.map(\.pid).sorted())
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

    /// Fire-and-forget. For every process of the app, reads all window bounds
    /// first, then moves the ones not already on the active display.
    static func relocate(_ app: RelocatableApp) {
        guard let screens = activeScreenRects() else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            for pid in app.pids {
                guard let windows = AppleEventWindows.boundsOfEveryWindow(pid: pid) else {
                    log.error("Could not read window bounds for \(app.id, privacy: .public) pid \(pid) (permission denied or no window support)")
                    continue
                }
                for (offset, window) in windows.enumerated() {
                    guard let window, let target = WindowGeometry.targetBounds(for: window, in: screens) else { continue }
                    if !AppleEventWindows.setBounds(pid: pid, windowIndex: offset + 1, to: target) {
                        log.error("Could not move window \(offset + 1) of \(app.id, privacy: .public) pid \(pid)")
                    }
                }
            }
        }
    }
}
