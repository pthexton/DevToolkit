import CoreGraphics

/// The screen facts the fit math needs, both in NSScreen (bottom-left origin)
/// coordinates.
struct ScreenRects {
    /// Height of the primary (menu-bar) screen. Apple Event window bounds are
    /// measured from this screen's top-left corner.
    let primaryHeight: CGFloat
    /// Visible frame (below the menu bar, above the Dock) of the screen the
    /// windows should be pulled onto.
    let targetVisibleFrame: CGRect
}

/// Pure coordinate and fit math for relocating windows. Windows are in
/// Apple Event space: top-left origin, measured from the primary screen.
enum WindowGeometry {
    /// Returns nil when `window` already lies fully inside the target visible
    /// frame; otherwise the rect it should move to. The size is kept where it
    /// fits, shrunk to the visible frame where it does not, and the origin is
    /// clamped so the whole window is visible.
    static func targetBounds(for window: CGRect, in screens: ScreenRects) -> CGRect? {
        let visible = visibleTopLeft(screens)
        if visible.contains(window) { return nil }

        let width = min(window.width, visible.width)
        let height = min(window.height, visible.height)
        let x = min(max(window.minX, visible.minX), visible.maxX - width)
        let y = min(max(window.minY, visible.minY), visible.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// `{left, top, right, bottom}`, the order Apple Events use for `bounds`.
    static func appleEventBounds(_ rect: CGRect) -> [Int] {
        [Int(rect.minX.rounded()), Int(rect.minY.rounded()),
         Int(rect.maxX.rounded()), Int(rect.maxY.rounded())]
    }

    static func rect(fromAppleEventBounds b: [Int]) -> CGRect? {
        guard b.count == 4 else { return nil }
        return CGRect(x: b[0], y: b[1], width: b[2] - b[0], height: b[3] - b[1])
    }

    private static func visibleTopLeft(_ screens: ScreenRects) -> CGRect {
        let v = screens.targetVisibleFrame
        return CGRect(x: v.minX, y: screens.primaryHeight - v.maxY, width: v.width, height: v.height)
    }
}
