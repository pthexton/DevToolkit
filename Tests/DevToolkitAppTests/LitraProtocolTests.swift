import XCTest
@testable import DevToolkitApp

final class LitraProtocolTests: XCTestCase {
    private func padded(_ prefix: [UInt8]) -> [UInt8] {
        prefix + [UInt8](repeating: 0, count: 20 - prefix.count)
    }

    func testRequestsMatchLitraRs() {
        XCTAssertEqual(LitraProtocol.queryPower(), padded([0x11, 0xff, 0x04, 0x01]))
        XCTAssertEqual(LitraProtocol.queryBrightness(), padded([0x11, 0xff, 0x04, 0x31]))
        XCTAssertEqual(LitraProtocol.setPower(true), padded([0x11, 0xff, 0x04, 0x1c, 0x01]))
        XCTAssertEqual(LitraProtocol.setPower(false), padded([0x11, 0xff, 0x04, 0x1c, 0x00]))
        XCTAssertEqual(LitraProtocol.setBrightness(lumen: 250), padded([0x11, 0xff, 0x04, 0x4c, 0x00, 0xfa]))
    }

    func testTemperatureRequestsMatchLitraRs() {
        XCTAssertEqual(LitraProtocol.queryTemperature(), padded([0x11, 0xff, 0x04, 0x81]))
        XCTAssertEqual(LitraProtocol.setTemperature(kelvin: 6500), padded([0x11, 0xff, 0x04, 0x9c, 0x19, 0x64]))
        XCTAssertEqual(LitraProtocol.setTemperature(kelvin: 2700), padded([0x11, 0xff, 0x04, 0x9c, 0x0a, 0x8c]))
    }

    func testSetTemperatureClampsAndRoundsToHundreds() {
        XCTAssertEqual(LitraProtocol.setTemperature(kelvin: 1000), LitraProtocol.setTemperature(kelvin: 2700))
        XCTAssertEqual(LitraProtocol.setTemperature(kelvin: 9000), LitraProtocol.setTemperature(kelvin: 6500))
        XCTAssertEqual(LitraProtocol.setTemperature(kelvin: 4449), LitraProtocol.setTemperature(kelvin: 4400))
        XCTAssertEqual(LitraProtocol.setTemperature(kelvin: 4450), LitraProtocol.setTemperature(kelvin: 4500))
        XCTAssertEqual(LitraProtocol.setTemperature(kelvin: 6499), LitraProtocol.setTemperature(kelvin: 6500))
    }

    func testSetBrightnessClampsToGlowRange() {
        XCTAssertEqual(LitraProtocol.setBrightness(lumen: 5), LitraProtocol.setBrightness(lumen: 20))
        XCTAssertEqual(LitraProtocol.setBrightness(lumen: 400), LitraProtocol.setBrightness(lumen: 250))
    }

    // Byte sequences below were captured from a real Litra Glow.

    func testParsesGetReplies() {
        XCTAssertEqual(LitraProtocol.parse(padded([0x11, 0xff, 0x04, 0x01, 0x01])), .power(true))
        XCTAssertEqual(LitraProtocol.parse(padded([0x11, 0xff, 0x04, 0x01, 0x00])), .power(false))
        XCTAssertEqual(LitraProtocol.parse(padded([0x11, 0xff, 0x04, 0x31, 0x00, 0xa7])), .brightness(lumen: 167))
        XCTAssertEqual(LitraProtocol.parse(padded([0x11, 0xff, 0x04, 0x81, 0x19, 0x64])), .temperature(kelvin: 6500))
    }

    func testParsesChangeAnnouncements() {
        XCTAssertEqual(LitraProtocol.parse(padded([0x11, 0xff, 0x04, 0x0f, 0x01])), .power(true))
        XCTAssertEqual(LitraProtocol.parse(padded([0x11, 0xff, 0x04, 0x3f, 0x00, 0xa7])), .brightness(lumen: 167))
        XCTAssertEqual(LitraProtocol.parse(padded([0x11, 0xff, 0x04, 0x8f, 0x19, 0x00])), .temperature(kelvin: 6400))
    }

    func testParsesRepliesToOtherSoftware() {
        // Logi Options+ uses its own software ID; its replies still reflect real state.
        XCTAssertEqual(LitraProtocol.parse(padded([0x11, 0xff, 0x04, 0x3a, 0x00, 0x64])), .brightness(lumen: 100))
    }

    func testIgnoresSetAcknowledgements() {
        // Empty acks: reading them as state would report the light off / at 0 lm.
        XCTAssertNil(LitraProtocol.parse(padded([0x11, 0xff, 0x04, 0x1c, 0x00, 0x00])))
        XCTAssertNil(LitraProtocol.parse(padded([0x11, 0xff, 0x04, 0x4c, 0x00, 0x00])))
        XCTAssertNil(LitraProtocol.parse(padded([0x11, 0xff, 0x04, 0x9c, 0x00, 0x00])))
    }

    func testIgnoresUnrelatedReports() {
        XCTAssertNil(LitraProtocol.parse(padded([0x11, 0xff, 0x04, 0x21, 0x00, 0x14]))) // brightness info
        XCTAssertNil(LitraProtocol.parse(padded([0x11, 0xff, 0xff, 0x04, 0x31, 0x02]))) // HID++ error
        XCTAssertNil(LitraProtocol.parse(padded([0x11, 0xff, 0x05, 0x01, 0x01])))       // other feature
        XCTAssertNil(LitraProtocol.parse([0x11, 0xff, 0x04]))                            // short
        XCTAssertNil(LitraProtocol.parse(padded([0x10, 0xff, 0x04, 0x01, 0x01])))       // short HID++ report
    }

    func testMatchesRepliesToRequests() {
        let query = LitraProtocol.queryBrightness()
        XCTAssertTrue(LitraProtocol.isReply(padded([0x11, 0xff, 0x04, 0x31, 0x00, 0xa7]), to: query))
        XCTAssertTrue(LitraProtocol.isReply(padded([0x11, 0xff, 0xff, 0x04, 0x31, 0x02]), to: query)) // error
        XCTAssertFalse(LitraProtocol.isReply(padded([0x11, 0xff, 0x04, 0x01, 0x01]), to: query))      // other request
        XCTAssertFalse(LitraProtocol.isReply(padded([0x11, 0xff, 0x04, 0x3a, 0x00, 0x64]), to: query)) // other software
        XCTAssertFalse(LitraProtocol.isReply(padded([0x11, 0xff, 0x04, 0x3f, 0x00, 0xa7]), to: query)) // announcement
        XCTAssertFalse(LitraProtocol.isReply(padded([0x11, 0xff, 0xff, 0x04, 0x01, 0x02]), to: query)) // error for other
        XCTAssertTrue(LitraProtocol.isReply(padded([0x11, 0xff, 0x04, 0x4c, 0x00, 0x00]),
                                            to: LitraProtocol.setBrightness(lumen: 135)))
    }

    func testPercentMappingMatchesLitraRs() {
        XCTAssertEqual(LitraProtocol.lumen(forPercent: 0), 20)
        XCTAssertEqual(LitraProtocol.lumen(forPercent: 1), 23)   // ceil(2.3) + 20
        XCTAssertEqual(LitraProtocol.lumen(forPercent: 50), 135)
        XCTAssertEqual(LitraProtocol.lumen(forPercent: 100), 250)
        XCTAssertEqual(LitraProtocol.lumen(forPercent: 150), 250)
        XCTAssertEqual(LitraProtocol.percent(forLumen: 20), 0)
        XCTAssertEqual(LitraProtocol.percent(forLumen: 135), 50)
        XCTAssertEqual(LitraProtocol.percent(forLumen: 250), 100)
        XCTAssertEqual(LitraProtocol.percent(forLumen: 1000), 100)
    }

    func testPercentRoundTripsForMenuSteps() {
        for step in stride(from: 10, through: 100, by: 10) {
            XCTAssertEqual(LitraProtocol.percent(forLumen: LitraProtocol.lumen(forPercent: step)), step)
        }
    }
}
