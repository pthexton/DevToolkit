import XCTest
@testable import DevToolkitApp

final class WindowRelocatorTests: XCTestCase {
    func testScriptableViaBooleanKey() {
        XCTAssertTrue(WindowRelocator.isScriptable(infoDictionary: ["NSAppleScriptEnabled": true]))
    }

    func testScriptableViaSafarisStringKey() {
        XCTAssertTrue(WindowRelocator.isScriptable(infoDictionary: ["NSAppleScriptEnabled": "Yes"]))
    }

    func testScriptableViaScriptingDefinition() {
        XCTAssertTrue(WindowRelocator.isScriptable(infoDictionary: ["OSAScriptingDefinition": "UTM.sdef"]))
    }

    func testNotScriptable() {
        XCTAssertFalse(WindowRelocator.isScriptable(infoDictionary: [:]))
        XCTAssertFalse(WindowRelocator.isScriptable(infoDictionary: nil))
        XCTAssertFalse(WindowRelocator.isScriptable(infoDictionary: ["NSAppleScriptEnabled": false]))
        XCTAssertFalse(WindowRelocator.isScriptable(infoDictionary: ["OSAScriptingDefinition": ""]))
    }

    /// Malformed lines stay in place as nil so window indices (1-based in
    /// Apple Events) still line up with the array positions.
    func testParseBoundsListKeepsIndicesAligned() {
        let raw = "194,658,1094,1310\nnot,bounds\n0,0,100,50\n"
        XCTAssertEqual(WindowRelocator.parseBoundsList(raw),
                       [CGRect(x: 194, y: 658, width: 900, height: 652),
                        nil,
                        CGRect(x: 0, y: 0, width: 100, height: 50)])
    }
}
