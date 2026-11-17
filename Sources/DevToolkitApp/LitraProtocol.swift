import Foundation

/// Wire format for the Logitech Litra Glow key light, a HID++ 2.0 device.
///
/// Request bytes follow timrogers/litra-rs (src/lib.rs). Reply and
/// announcement behaviour was measured on a real Glow (Nov 2026) and is
/// recorded below, because litra-rs only reads replies to its own queries.
///
/// ## Transport
///
/// The Glow (vendor 0x046d, product 0xc900) has a single USB HID interface
/// carrying two top-level collections: consumer controls (usage page 0x0c)
/// and a vendor collection (usage page 0xff43) that speaks HID++. Requests are
/// output reports and replies are input reports, both 20 bytes, with the
/// report ID as the first byte of the buffer. No feature reports are used.
/// Opening the interface does not need exclusive access, so Logi Options+ can
/// keep it open at the same time.
///
/// ## Message layout
///
///     [0] 0x11  report ID (HID++ "long" report)
///     [1] 0xff  device index (the light itself; there is no receiver)
///     [2] 0x04  feature index of the Glow's illumination feature
///     [3]       function << 4 | software ID
///     [4...]    parameters, big-endian, zero padded to 20 bytes
///
/// The software ID (low nibble of byte 3) lets several programs share the
/// device: a reply echoes the request's byte 3, so each program can recognise
/// its own replies. litra-rs uses 1 for gets and 0xc for sets; DevToolkit
/// does the same.
///
/// ## Functions of the illumination feature (index 0x04)
///
///     function  request  meaning              parameters
///     0         0x01     get power            reply [4]: 1 on, 0 off
///     1         0x1c     set power            [4]: 1 on, 0 off
///     3         0x31     get brightness       reply [4...5]: lumen
///     4         0x4c     set brightness       [4...5]: lumen, 20...250
///     8         0x81     get colour temp      reply [4...5]: kelvin
///     9         0x9c     set colour temp      [4...5]: kelvin, 2700...6500,
///                                             a multiple of 100
///
/// ## Measured reply behaviour
///
/// - Get replies carry the value, as in the table above.
/// - Set replies are an empty acknowledgement (`1c 00 00`, `4c 00 00`,
///   `9c 00 00`). They do not carry the applied value.
/// - After any change, whoever caused it, the light announces the new value
///   using the matching get function with software ID 0xf: `0f 01` (power),
///   `3f 00 a7` (167 lm), `8f 19 64` (6500 K).
/// - The light handles one request at a time. A request that arrives while
///   another is unanswered is dropped without an error, so senders must wait
///   for `isReply` (or a timeout) before sending the next one.
/// - Errors come back as `11 ff ff <feature> <function byte> <error code>`.
///
/// So the high nibble of byte 3 identifies the value whatever the software
/// ID: 0 is power, 3 is brightness, 8 is colour temperature. `parse` relies on
/// this, so replies to Logi Options+ keep DevToolkit's view current too.
///
/// ## Colour
///
/// The Glow's LEDs are white only. It has no hue or RGB control; colour
/// temperature (warm 2700 K to cool 6500 K) is the only colour setting. To let
/// the user choose it, add a menu `Picker` like the brightness one that calls
/// `setTemperature(kelvin:)`, and change or remove
/// `LitraGlowFeature.pinnedTemperature`, which otherwise puts the light back.
///
/// RGB exists only on the back panel of the Litra Beam LX (product 0xc903),
/// through separate features in litra-rs: feature 0x0c function 1 sets one
/// zone's colour (`11 ff 0c 1b <zone 1...7> <r> <g> <b> ff 00 00 00 ff ...`),
/// and feature 0x0a controls the back panel's power (`4b`) and brightness
/// (`2b`). The Beam LX also moves the front illumination feature to index
/// 0x06. None of that applies to the Glow.
enum LitraProtocol {
    static let vendorID = 0x046d
    static let glowProductID = 0xc900
    static let usagePage = 0xff43

    static let reportID: UInt8 = 0x11
    static let reportLength = 20

    static let minimumLumen: UInt16 = 20
    static let maximumLumen: UInt16 = 250

    static let minimumKelvin: UInt16 = 2700
    static let maximumKelvin: UInt16 = 6500
    static let kelvinStep: UInt16 = 100

    private static let deviceIndex: UInt8 = 0xff
    private static let featureIndex: UInt8 = 0x04

    // Request function bytes (function << 4 | software ID), from litra-rs.
    private static let getPower: UInt8 = 0x01
    private static let setPower: UInt8 = 0x1c
    private static let getBrightness: UInt8 = 0x31
    private static let setBrightness: UInt8 = 0x4c
    private static let getTemperature: UInt8 = 0x81
    private static let setTemperature: UInt8 = 0x9c

    /// State the light reported, from a get reply or a change announcement.
    enum Update: Equatable {
        case power(Bool)
        case brightness(lumen: UInt16)
        case temperature(kelvin: UInt16)
    }

    static func queryPower() -> [UInt8] { message(getPower) }
    static func queryBrightness() -> [UInt8] { message(getBrightness) }
    static func queryTemperature() -> [UInt8] { message(getTemperature) }

    static func setPower(_ on: Bool) -> [UInt8] {
        message(setPower, on ? 1 : 0)
    }

    /// Clamped to the Glow's supported range.
    static func setBrightness(lumen: UInt16) -> [UInt8] {
        message(setBrightness, word: min(max(lumen, minimumLumen), maximumLumen))
    }

    /// Clamped to the Glow's range and rounded to the nearest 100 K, the only
    /// values the light accepts.
    static func setTemperature(kelvin: UInt16) -> [UInt8] {
        let clamped = min(max(kelvin, minimumKelvin), maximumKelvin)
        let rounded = (clamped + kelvinStep / 2) / kelvinStep * kelvinStep
        return message(setTemperature, word: min(rounded, maximumKelvin))
    }

    /// Decodes an input report. Returns nil for anything that is not state
    /// from the illumination feature: set acknowledgements, other functions,
    /// and HID++ error replies (those carry feature index 0xff).
    static func parse(_ report: [UInt8]) -> Update? {
        guard report.count >= 6,
              report[0] == reportID,
              report[2] == featureIndex else { return nil }
        let word = UInt16(report[4]) << 8 | UInt16(report[5])
        switch report[3] >> 4 {
        case 0: return .power(report[4] == 1)
        case 3: return .brightness(lumen: word)
        case 8: return .temperature(kelvin: word)
        default: return nil
        }
    }

    /// True when `report` answers `request`: either the success reply, which
    /// echoes the request's feature and function bytes, or a HID++ error reply
    /// (`0x11 0xff 0xff <feature> <function> <error>`). The light handles one
    /// request at a time and drops a request that arrives while another is
    /// outstanding, so callers wait for this before sending the next one.
    static func isReply(_ report: [UInt8], to request: [UInt8]) -> Bool {
        guard report.count >= 5, request.count >= 4, report[0] == reportID else { return false }
        if report[2] == request[2] { return report[3] == request[3] }
        return report[2] == 0xff && report[3] == request[2] && report[4] == request[3]
    }

    /// Same mapping as litra-rs's `--percentage`: 0% is the minimum, 100% the
    /// maximum, and values in between round up so 1% is brighter than 0%.
    static func lumen(forPercent percent: Int) -> UInt16 {
        let percent = min(max(percent, 0), 100)
        let range = Double(maximumLumen - minimumLumen)
        return minimumLumen + UInt16((Double(percent) / 100 * range).rounded(.up))
    }

    static func percent(forLumen lumen: UInt16) -> Int {
        let lumen = min(max(lumen, minimumLumen), maximumLumen)
        let range = Double(maximumLumen - minimumLumen)
        return Int((Double(lumen - minimumLumen) / range * 100).rounded())
    }

    private static func message(_ function: UInt8, word: UInt16) -> [UInt8] {
        message(function, UInt8(word >> 8), UInt8(word & 0xff))
    }

    private static func message(_ function: UInt8, _ parameters: UInt8...) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: reportLength)
        bytes[0] = reportID
        bytes[1] = deviceIndex
        bytes[2] = featureIndex
        bytes[3] = function
        for (offset, value) in parameters.enumerated() { bytes[4 + offset] = value }
        return bytes
    }
}
