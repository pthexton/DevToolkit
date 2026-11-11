import Foundation

/// Pure rendering of the now-playing screen for the 128x64 OLED. No I/O.
///
///     64x64 artwork | title
///                   | album
///                   | artist
///                   | 1:23 / 4:56
///                   | [progress bar]
///
/// Text rows wider than the 60px column scroll as a marquee: hold, scroll to
/// the end, hold, then jump back to the start.
enum NowPlayingFrame {
    static let artSize = 64
    static let textX = 68
    static let textWidth = ClockFrame.width - textX
    /// Top pixel row of the title, album, artist and position lines.
    static let rowY = [2, 17, 32, 47]
    static let barTop = 57
    static let barBottom = 61

    static let holdSeconds = 1.5
    /// Whole pixels per frame at `frameInterval` keeps the scroll even and
    /// the HID write rate modest.
    static let scrollPixelsPerSecond = 10.0
    static let frameInterval = 0.1

    /// Horizontal scroll offset of a row `elapsed` seconds after the scene started.
    static func marqueeOffset(contentWidth: Int, windowWidth: Int, elapsed: TimeInterval) -> Int {
        let overflow = contentWidth - windowWidth
        guard overflow > 0 else { return 0 }
        let scrollTime = Double(overflow) / scrollPixelsPerSecond
        let phase = max(0, elapsed).truncatingRemainder(dividingBy: holdSeconds + scrollTime + holdSeconds)
        if phase < holdSeconds { return 0 }
        if phase < holdSeconds + scrollTime { return min(overflow, Int((phase - holdSeconds) * scrollPixelsPerSecond)) }
        return overflow
    }

    /// "m:ss" with whole-second accuracy.
    static func formatClock(_ seconds: TimeInterval) -> String {
        let whole = Int(max(0, seconds))
        return "\(whole / 60):" + String(format: "%02d", whole % 60)
    }

    /// - Parameters:
    ///   - date: the instant being rendered, used to extrapolate the position.
    ///   - sinceStart: seconds since this track's screen first appeared; drives the marquee.
    static func scene(for track: NowPlayingTrack, at date: Date, sinceStart: TimeInterval) -> ClockFrame.Scene {
        var pixels = [Bool](repeating: false, count: ClockFrame.width * ClockFrame.height)

        if let artwork = track.artwork, artwork.count == artSize * artSize {
            for y in 0..<artSize {
                for x in 0..<artSize where artwork[y * artSize + x] { pixels[y * ClockFrame.width + x] = true }
            }
        }

        let position = track.position(at: date)
        let rows = [PixelFont.normalise(track.title), PixelFont.normalise(track.album),
                    PixelFont.normalise(track.artist),
                    "\(formatClock(position)) / \(formatClock(track.duration))"]
        var scrolling = false
        for (text, top) in zip(rows, rowY) {
            let width = PixelFont.width(of: text)
            scrolling = scrolling || width > textWidth
            let offset = marqueeOffset(contentWidth: width, windowWidth: textWidth, elapsed: sinceStart)
            draw(text, left: textX - offset, top: top, clip: textX..<ClockFrame.width, into: &pixels)
        }

        drawProgressBar(fraction: track.duration > 0 ? position / track.duration : 0, into: &pixels)

        // Re-render when the displayed second changes, or per scroll frame.
        let fraction = position - position.rounded(.down)
        let untilNextSecond = track.rate > 0 ? (1 - fraction) / track.rate : 1
        let refreshAfter = scrolling ? min(frameInterval, untilNextSecond) : untilNextSecond
        return ClockFrame.Scene(pixels: pixels, description: "Now playing: \(track.title)",
                                refreshAfter: max(0.05, refreshAfter))
    }

    private static func draw(_ text: String, left: Int, top: Int, clip: Range<Int>, into pixels: inout [Bool]) {
        var cursor = left
        for character in text {
            guard let glyph = PixelFont.glyphs[character] else { continue }
            for (row, line) in glyph.enumerated() {
                for (column, lit) in line.enumerated() where lit {
                    let x = cursor + column, y = top + row
                    if clip.contains(x), (0..<ClockFrame.height).contains(y) { pixels[y * ClockFrame.width + x] = true }
                }
            }
            cursor += (glyph.first?.count ?? 0) + 1
        }
    }

    /// A 1px outline spanning the text column, filled left to right inside.
    private static func drawProgressBar(fraction: Double, into pixels: inout [Bool]) {
        let width = ClockFrame.width
        for x in textX..<width {
            pixels[barTop * width + x] = true
            pixels[barBottom * width + x] = true
        }
        for y in barTop...barBottom {
            pixels[y * width + textX] = true
            pixels[y * width + width - 1] = true
        }
        let inner = width - 1 - (textX + 1)
        let filled = Int(Double(inner) * min(1, max(0, fraction)))
        for x in 0..<filled {
            for y in (barTop + 1)..<barBottom { pixels[y * width + textX + 1 + x] = true }
        }
    }
}
