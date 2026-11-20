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

    /// Two `rockit run` processes share one bundle id: they must become a
    /// single menu row that relocates both, not two rows with the same id.
    func testProcessesSharingABundleIDGroupIntoOneApp() {
        let apps = WindowRelocator.grouped([
            (id: "com.beyondtrust.pomona.rockit", name: "Rockit", icon: nil, pid: 300),
            (id: "com.utmapp.UTM", name: "UTM", icon: nil, pid: 100),
            (id: "com.beyondtrust.pomona.rockit", name: "Rockit", icon: nil, pid: 200),
        ])
        XCTAssertEqual(apps.map(\.id), ["com.beyondtrust.pomona.rockit", "com.utmapp.UTM"])
        XCTAssertEqual(apps.map(\.name), ["Rockit", "UTM"])
        XCTAssertEqual(apps[0].pids, [200, 300])
        XCTAssertEqual(apps[1].pids, [100])
    }
}

final class AppleEventWindowsTests: XCTestCase {
    /// `qdrt` is top, left, bottom, right as Int16, which is what UTM returns
    /// for `bounds of window 1`.
    private func qdrt(top: Int16, left: Int16, bottom: Int16, right: Int16) -> NSAppleEventDescriptor {
        let values = [top, left, bottom, right]
        let data = values.withUnsafeBufferPointer { Data(buffer: $0) }
        return NSAppleEventDescriptor(descriptorType: typeQDRectangle, data: data)!
    }

    private func intList(_ values: [Int32]) -> NSAppleEventDescriptor {
        let list = NSAppleEventDescriptor.list()
        for (i, v) in values.enumerated() { list.insert(NSAppleEventDescriptor(int32: v), at: i + 1) }
        return list
    }

    private func list(_ items: [NSAppleEventDescriptor]) -> NSAppleEventDescriptor {
        let list = NSAppleEventDescriptor.list()
        for (i, item) in items.enumerated() { list.insert(item, at: i + 1) }
        return list
    }

    func testDecodesAListOfQuickDrawRectangles() {
        let reply = list([qdrt(top: 658, left: 194, bottom: 1310, right: 1094),
                          qdrt(top: 33, left: 554, bottom: 866, right: 1744)])
        XCTAssertEqual(AppleEventWindows.decodeBounds(reply),
                       [CGRect(x: 194, y: 658, width: 900, height: 652),
                        CGRect(x: 554, y: 33, width: 1190, height: 833)])
    }

    func testDecodesAListOfIntegerLists() {
        let reply = list([intList([642, 332, 2119, 1248])])
        XCTAssertEqual(AppleEventWindows.decodeBounds(reply),
                       [CGRect(x: 642, y: 332, width: 1477, height: 916)])
    }

    func testNoWindowsDecodesToEmpty() {
        XCTAssertEqual(AppleEventWindows.decodeBounds(NSAppleEventDescriptor.list()), [])
    }

    /// A malformed entry stays in place as nil so 1-based window indices
    /// still line up with array positions.
    func testMalformedEntryKeepsIndicesAligned() {
        let reply = list([intList([1, 2, 3]), intList([0, 0, 100, 50])])
        XCTAssertEqual(AppleEventWindows.decodeBounds(reply),
                       [nil, CGRect(x: 0, y: 0, width: 100, height: 50)])
    }
}
