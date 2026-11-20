import XCTest
@testable import DevToolkitApp

final class WindowGeometryTests: XCTestCase {
    // Real layout: DELL 2560x1440 primary at the origin, built-in to its right
    // (bottom-left coordinates). In top-left Apple Event terms the built-in's
    // visible area is x 2560...4288, y 32...1117.
    private let screens = ScreenRects(
        primaryHeight: 1440,
        targetVisibleFrame: CGRect(x: 2560, y: 323, width: 1728, height: 1085)
    )
    private let visibleTopLeft = CGRect(x: 2560, y: 32, width: 1728, height: 1085)

    func testWindowOnOtherScreenIsMovedKeepingSize() throws {
        let window = CGRect(x: 100, y: 100, width: 900, height: 652)
        let moved = try XCTUnwrap(WindowGeometry.targetBounds(for: window, in: screens))
        XCTAssertEqual(moved.size, window.size)
        XCTAssertTrue(visibleTopLeft.contains(moved))
    }

    func testOversizedWindowShrinksToVisibleFrame() {
        let window = CGRect(x: 100, y: 100, width: 2000, height: 1300)
        XCTAssertEqual(WindowGeometry.targetBounds(for: window, in: screens),
                       CGRect(x: 2560, y: 32, width: 1728, height: 1085))
    }

    func testWindowAlreadyInsideReturnsNil() {
        let window = CGRect(x: 2700, y: 100, width: 800, height: 600)
        XCTAssertNil(WindowGeometry.targetBounds(for: window, in: screens))
    }

    func testStraddlingWindowIsMoved() throws {
        let window = CGRect(x: 2000, y: 100, width: 1200, height: 600)
        let moved = try XCTUnwrap(WindowGeometry.targetBounds(for: window, in: screens))
        XCTAssertTrue(visibleTopLeft.contains(moved))
    }

    func testAppleEventBoundsRoundTrip() {
        let rect = CGRect(x: 10, y: 20, width: 30, height: 40)
        XCTAssertEqual(WindowGeometry.appleEventBounds(rect), [10, 20, 40, 60])
        XCTAssertEqual(WindowGeometry.rect(fromAppleEventBounds: [10, 20, 40, 60]), rect)
        XCTAssertNil(WindowGeometry.rect(fromAppleEventBounds: [1, 2, 3]))
    }
}
