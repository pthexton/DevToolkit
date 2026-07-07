import AppKit

/// A borderless, non-activating floating panel that still accepts key focus
/// immediately - unlike a passive notification overlay, this one's whole
/// point is instant typing (Spotlight-style), so it must become key and take
/// keyboard input the moment it's shown.
final class OverlayPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .popUpMenu
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        animationBehavior = .utilityWindow
        refreshSpaceMembership()
    }

    /// Re-asserts `.canJoinAllSpaces` collection behaviour. `NSWindow`'s
    /// cross-Space/cross-display registration with WindowServer isn't always
    /// dynamic in practice - with "Displays have separate Spaces" enabled, a
    /// reused panel has been observed getting latched to whichever
    /// display/Space was active when WindowServer last evaluated it, only
    /// showing on that one display until something forces a re-evaluation.
    /// Called on init and again before every `show()` so each appearance
    /// gets a fresh evaluation instead of trusting stale registration.
    func refreshSpaceMembership() {
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
