import AppKit
import SwiftUI

/// Owns the overlay panel's lifecycle: showing/hiding/toggling it, restoring
/// whatever app was frontmost before we forcibly activated ourselves to grab
/// keyboard focus, refreshing search results, and routing arrow/enter/escape
/// keys to the view model (SwiftUI's focus model doesn't give a clean hook
/// for list navigation, so a local key monitor handles those three keys and
/// lets everything else fall through to the text field for typing).
@MainActor
final class OverlayController {
    private let viewModel = SearchViewModel()
    private let providers: [WindowProvider]

    private var panel: OverlayPanel?
    private var previousApp: NSRunningApplication?
    private var keyMonitor: Any?

    init(providers: [WindowProvider] = [
        SafariProvider(),
        ChromeProvider(),
        ITerm2Provider(),
        GhosttyProvider(),
        TerminalAppProvider()
    ]) {
        self.providers = providers
        viewModel.onSelect = { [weak self] item in self?.activate(item) }
        viewModel.onCancel = { [weak self] in self?.hide() }
        installKeyMonitor()
    }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle() {
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    private func show() {
        previousApp = NSWorkspace.shared.frontmostApplication
        viewModel.reset()

        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.refreshSpaceMembership()
        position(panel)

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        viewModel.requestFocus()

        refreshItems()
    }

    private func hide(restoringFocus: Bool = true) {
        panel?.orderOut(nil)
        if restoringFocus {
            previousApp?.activate(options: [.activateIgnoringOtherApps])
        }
        previousApp = nil
    }

    private func activate(_ item: SwitchItem) {
        hide(restoringFocus: false)
        item.activate()
    }

    private func refreshItems() {
        let providers = self.providers
        Task.detached {
            let excludedBundleIDs = Set(providers.flatMap { type(of: $0).supportedBundleIDs })
            var items: [SwitchItem] = []
            for provider in providers where provider.isAvailable() {
                items.append(contentsOf: provider.fetchItems())
            }
            items.append(contentsOf: RunningAppsProvider(excludedBundleIDs: excludedBundleIDs).fetchItems())
            let fetchedItems = items
            await MainActor.run {
                self.viewModel.allItems = fetchedItems
            }
        }
    }

    private func makePanel() -> OverlayPanel {
        let panel = OverlayPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 420))
        panel.contentView = NSHostingView(rootView: SearchView(viewModel: viewModel))
        return panel
    }

    private func position(_ panel: NSPanel) {
        guard let screen = activeScreen() else { return }
        let width: CGFloat = 640
        let height: CGFloat = 420
        let frame = screen.visibleFrame
        let x = frame.midX - width / 2
        let y = frame.maxY - frame.height * 0.28 - height
        panel.setFrame(NSRect(x: x, y: max(y, frame.minY), width: width, height: height), display: true)
    }

    private func activeScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, self.isVisible else { return event }
            switch event.keyCode {
            case 125: // down arrow
                self.viewModel.moveSelection(by: 1)
                return nil
            case 126: // up arrow
                self.viewModel.moveSelection(by: -1)
                return nil
            case 36, 76: // return / keypad enter
                self.viewModel.selectCurrent()
                return nil
            case 53: // escape
                self.hide()
                return nil
            case 29 where event.modifierFlags.contains(.command): // cmd+0
                self.viewModel.setMode(.all)
                return nil
            case 18 where event.modifierFlags.contains(.command): // cmd+1
                self.viewModel.setMode(.apps)
                return nil
            case 19 where event.modifierFlags.contains(.command): // cmd+2
                self.viewModel.setMode(.browserTabs)
                return nil
            case 20 where event.modifierFlags.contains(.command): // cmd+3
                self.viewModel.setMode(.terminalTabs)
                return nil
            default:
                return event
            }
        }
    }
}
