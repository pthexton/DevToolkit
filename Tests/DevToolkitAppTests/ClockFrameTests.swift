import XCTest
@testable import DevToolkitApp

final class ClockFrameTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(hour: Int, minute: Int, second: Double = 0) -> Date {
        let whole = Int(second)
        let base = calendar.date(from: DateComponents(year: 2026, month: 11, day: 5,
                                                     hour: hour, minute: minute, second: whole))!
        return base.addingTimeInterval(second - Double(whole))
    }

    func testDaytimeSceneShowsTimeAndRefreshesAtNextMinute() {
        let scene = ClockFrame.scene(at: date(hour: 13, minute: 3, second: 12.5), calendar: calendar)
        XCTAssertEqual(scene.description, "13:03")
        XCTAssertEqual(scene.refreshAfter, 30, accuracy: 0.001) // heartbeat cap, boundary is 47.5s away
        let nearBoundary = ClockFrame.scene(at: date(hour: 13, minute: 3, second: 45.25), calendar: calendar)
        XCTAssertEqual(nearBoundary.refreshAfter, 14.75, accuracy: 0.001)
    }

    func testSceneFlipsToNextMinuteExactlyAtBoundary() {
        XCTAssertEqual(ClockFrame.scene(at: date(hour: 13, minute: 3, second: 59.998), calendar: calendar).description, "13:03")
        XCTAssertEqual(ClockFrame.scene(at: date(hour: 13, minute: 4, second: 0.002), calendar: calendar).description, "13:04")
    }

    func testNightSceneIsBlackExceptKittyCameo() {
        let kitty = ClockFrame.scene(at: date(hour: 22, minute: 0, second: 1), calendar: calendar)
        XCTAssertEqual(kitty.description, "Sleeping kitty")
        XCTAssertTrue(kitty.pixels.contains(true))
        let black = ClockFrame.scene(at: date(hour: 22, minute: 2), calendar: calendar)
        XCTAssertFalse(black.pixels.contains(true))
    }

    func testReportsLayout() {
        let reports = ClockFrame.reports(ClockFrame.pixels("12:34"))
        XCTAssertEqual(reports.count, 2)
        for (index, report) in reports.enumerated() {
            XCTAssertEqual(report.count, 1024)
            XCTAssertEqual(Array(report[0..<6]), [6, 0x93, UInt8(index * 64), 0, 64, 64])
        }
        XCTAssertTrue(reports.contains { $0[6...].contains { $0 != 0 } })
    }
}
