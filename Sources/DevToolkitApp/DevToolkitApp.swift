import SwiftUI
import AppKit
import Carbon.HIToolbox
import ServiceManagement
import OSLog

private let log = Logger(subsystem: "com.beyondtrust.devtoolkit", category: "app")

@main
struct DevToolkitApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra("DevToolkit", systemImage: "arrow.left.arrow.right.square") {
            Button("Show DevToolkit") { delegate.overlay.toggle() }
                .keyboardShortcut("k")
            Divider()
            Button("Quit DevToolkit") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let overlay = OverlayController()
    private var hotKey: HotKeyManager?
    private var ghosttyQuickTerminalHotKey: HotKeyManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard becomeCanonicalInstance() else { return }

        // Menu-bar only: no Dock icon, never steals focus except while the
        // overlay itself is showing.
        NSApp.setActivationPolicy(.accessory)

        hotKey = HotKeyManager { [weak self] in
            self?.overlay.toggle()
        }
        if hotKey == nil {
            log.error("Failed to register global hotkey (Option+Space)")
        }

        // Cmd+0 is also the overlay's own "All" search mode shortcut while
        // it's open (SearchMode.all), so only proxy to Ghostty when the
        // overlay isn't the one that should be handling the key.
        ghosttyQuickTerminalHotKey = HotKeyManager(keyCode: UInt32(kVK_ANSI_0), modifiers: UInt32(cmdKey)) { [weak self] in
            guard let self, !self.overlay.isVisible else { return }
            GhosttyQuickTerminal.toggle()
        }
        if ghosttyQuickTerminalHotKey == nil {
            log.error("Failed to register global hotkey (Cmd+0, Ghostty quick terminal)")
        }
    }

    /// Self-registers as a login-item LaunchAgent via `SMAppService` so
    /// DevToolkit starts at login and (on a launchd-managed re-launch)
    /// hands off cleanly instead of running duplicate copies.
    private func becomeCanonicalInstance() -> Bool {
        if ProcessInfo.processInfo.environment["DEVTOOLKIT_LAUNCHD"] == "1" {
            return true // launchd started us -- the real instance
        }

        let service = SMAppService.agent(plistName: "com.beyondtrust.devtoolkit.plist")
        do {
            if service.status != .enabled { try service.register() }
            log.notice("SMAppService registered (status \(service.status.rawValue))")
        } catch {
            // Non-blessed location (e.g. dev build dir) -- run as-is so the
            // app still works, just without the login-item registration.
            log.error("SMAppService register failed: \(error.localizedDescription, privacy: .public)")
            return true
        }

        // Registered. RunAtLoad starts the canonical instance; this copy exits.
        NSApp.setActivationPolicy(.prohibited)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { exit(0) }
        return false
    }
}
