import Foundation

/// Pure rendering logic for the SteelSeries base-station OLED (128x64, 1 bpp).
/// No I/O happens here, which keeps it unit-testable.
enum ClockFrame {
    static let width = 128
    static let height = 64

    static let glyphs: [Character: [String]] = [
        "0": ["01110", "10001", "10011", "10101", "11001", "10001", "01110"],
        "1": ["00100", "01100", "00100", "00100", "00100", "00100", "01110"],
        "2": ["01110", "10001", "00001", "00010", "00100", "01000", "11111"],
        "3": ["11110", "00001", "00001", "01110", "00001", "00001", "11110"],
        "4": ["00010", "00110", "01010", "10010", "11111", "00010", "00010"],
        "5": ["11111", "10000", "10000", "11110", "00001", "00001", "11110"],
        "6": ["01110", "10000", "10000", "11110", "10001", "10001", "01110"],
        "7": ["11111", "00001", "00010", "00100", "01000", "01000", "01000"],
        "8": ["01110", "10001", "10001", "01110", "10001", "10001", "01110"],
        "9": ["01110", "10001", "10001", "01111", "00001", "00001", "01110"],
        ":": ["00000", "00100", "00100", "00000", "00100", "00100", "00000"]
    ]

    /// Each glyph pixel is drawn as a `scale` x `scale` block.
    static let scale = 3
    /// "HH:MM": five 5-column glyphs with a 1-column gap between them.
    static let clockWidth = (5 * 5 + 4) * scale
    static let clockHeight = 7 * scale
    /// Number of distinct top-left positions the clock can take on the panel.
    static let travelX = width - clockWidth + 1
    static let travelY = height - clockHeight + 1

    /// Burn-in protection: a different clock position every minute. The steps
    /// are coprime with the travel ranges, so the walk visits every position
    /// before repeating, and consecutive minutes never land near each other
    /// (no digit stays lit in the same place from one minute to the next).
    static func clockOrigin(minuteIndex: Int) -> (x: Int, y: Int) {
        let x = ((minuteIndex * 17) % travelX + travelX) % travelX
        let y = ((minuteIndex * 23) % travelY + travelY) % travelY
        return (x, y)
    }

    static func pixels(_ text: String, x originX: Int = 20, y originY: Int = 21) -> [Bool] {
        var pixels = [Bool](repeating: false, count: width * height)
        for (index, character) in text.enumerated() {
            guard let glyph = glyphs[character] else { continue }
            for (row, line) in glyph.enumerated() {
                for (column, bit) in line.enumerated() where bit == "1" {
                    for dy in 0..<scale {
                        for dx in 0..<scale {
                            let x = originX + index * 6 * scale + column * scale + dx
                            let y = originY + row * scale + dy
                            if (0..<width).contains(x) && (0..<height).contains(y) { pixels[y * width + x] = true }
                        }
                    }
                }
            }
        }
        return pixels
    }

    // Sparse, hand-drawn bitmap: curled body, sleeping face, ears and a Z.
    static let cat = [
        "                         #####",
        "                            # ",
        "                           #  ",
        "                          #   ",
        "                         #####",
        "                              ",
        "   #     #                    ",
        "  # #   # #      #######       ",
        "  #  ###  #   ###       ###    ",
        " #         ###            #   ",
        " #  ## ##  #               #  ",
        " #    #    #                # ",
        "  #       #      #####      # ",
        "   #######     ##     #     # ",
        "    #         #       #    #  ",
        "     ##        #######   ##   ",
        "       ##################     "
    ]

    struct Scene {
        let pixels: [Bool]
        let description: String
        /// Seconds from the rendered instant until the picture should change
        /// (or be re-sent as a heartbeat).
        let refreshAfter: TimeInterval
    }

    /// Daytime shows the clock, moving to a new position every minute to avoid
    /// OLED burn-in. From 21:00 to 07:00 the screen is black apart from a brief
    /// sleeping-kitty cameo at the start of each 5 minute slot.
    static func scene(at date: Date, calendar: Calendar = .current) -> Scene {
        let parts = calendar.dateComponents([.hour, .minute, .second, .nanosecond], from: date)
        let hour = parts.hour ?? 0
        let minute = parts.minute ?? 0
        let second = Double(parts.second ?? 0) + Double(parts.nanosecond ?? 0) / 1_000_000_000
        let slot = Int(date.timeIntervalSince1970 / 300)
        if hour >= 21 || hour < 7 {
            let phase = Double(minute % 5) * 60 + second
            var frame = [Bool](repeating: false, count: width * height)
            if phase < 10 {
                let catWidth = cat.map(\.count).max() ?? 30
                let x = ((slot * 37) % (129 - catWidth) + (129 - catWidth)) % (129 - catWidth)
                let y = ((slot * 19) % (65 - cat.count) + (65 - cat.count)) % (65 - cat.count)
                for (dy, row) in cat.enumerated() {
                    for (dx, pixel) in row.enumerated() where pixel == "#" {
                        frame[(y + dy) * width + x + dx] = true
                    }
                }
                return Scene(pixels: frame, description: "Sleeping kitty", refreshAfter: max(0.05, 10 - phase))
            }
            return Scene(pixels: frame, description: "Night: screen black", refreshAfter: max(0.05, min(30, 300 - phase)))
        }
        let text = String(format: "%02d:%02d", hour, minute)
        // Minute boundaries are multiples of 60s since the epoch (all real time
        // zone offsets are whole minutes), so position and time change together.
        let origin = clockOrigin(minuteIndex: Int((date.timeIntervalSince1970 / 60).rounded(.down)))
        return Scene(pixels: pixels(text, x: origin.x, y: origin.y), description: text,
                     refreshAfter: max(0.05, min(30, 60 - second)))
    }

    /// HID feature reports (report ID 6) that draw `pixels`: the panel is
    /// written as two 64x64 halves in column-major bit order.
    static func reports(_ pixels: [Bool]) -> [[UInt8]] {
        precondition(pixels.count == width * height)
        return [0, 64].map { startX in
            var report = [UInt8](repeating: 0, count: 1024)
            // Report 6, bitmap command, x, y, width, height.
            report.replaceSubrange(0..<6, with: [6, 0x93, UInt8(startX), 0, 64, 64])
            for x in 0..<64 {
                for y in 0..<64 where pixels[y * width + startX + x] {
                    let bit = x * 64 + y
                    report[6 + bit / 8] |= UInt8(1 << (bit % 8))
                }
            }
            return report
        }
    }
}
