import XCTest
import CoreGraphics
import ImageIO
@testable import DevToolkitApp

final class PixelFontTests: XCTestCase {
    func testNormaliseFoldsWhitespaceAccentsAndCase() {
        XCTAssertEqual(PixelFont.normalise("Emhyr\u{A0}Var Emreis"), "EMHYR VAR EMREIS") // NBSP
        XCTAssertEqual(PixelFont.normalise("Przyby\u{142}owicz"), "PRZYBYLOWICZ")
        XCTAssertEqual(PixelFont.normalise("Beyonc\u{E9}"), "BEYONCE")
        XCTAssertEqual(PixelFont.normalise("Don\u{2019}t \u{2014} Stop"), "DON'T - STOP")
        XCTAssertEqual(PixelFont.normalise("\u{1F3B5}"), "?")
    }

    func testWidthsUseTrimmedGlyphsWithOnePixelGap() {
        XCTAssertEqual(PixelFont.width(of: ""), 0)
        XCTAssertEqual(PixelFont.width(of: "A"), 5)
        XCTAssertEqual(PixelFont.width(of: "AA"), 11)
        XCTAssertEqual(PixelFont.width(of: ":"), 1)
        XCTAssertEqual(PixelFont.width(of: "A A"), 5 + 1 + 2 + 1 + 5)
    }
}

final class NowPlayingFrameTests: XCTestCase {
    private func track(title: String = "Song", duration: Double = 100, elapsed: Double = 50,
                       rate: Double = 1, artwork: [Bool]? = nil) -> NowPlayingTrack {
        NowPlayingTrack(title: title, artist: "Artist", album: "Album", duration: duration, elapsed: elapsed,
                        anchor: Date(timeIntervalSince1970: 1000), rate: rate, isPlaying: rate > 0, artwork: artwork)
    }

    private func lit(_ scene: ClockFrame.Scene, x: Int, y: Int) -> Bool {
        scene.pixels[y * ClockFrame.width + x]
    }

    func testMarqueeHoldsScrollsHoldsThenRestarts() {
        // 20px of overflow at 10px/s: 2s of scrolling between two 1.5s holds (5s cycle).
        func offset(_ t: Double) -> Int {
            NowPlayingFrame.marqueeOffset(contentWidth: 80, windowWidth: 60, elapsed: t)
        }
        XCTAssertEqual(offset(0), 0)
        XCTAssertEqual(offset(1.4), 0)
        XCTAssertEqual(offset(2.0), 5)
        XCTAssertEqual(offset(3.4), 19)
        XCTAssertEqual(offset(4.0), 20)
        XCTAssertEqual(offset(5.2), 0)
        XCTAssertEqual(NowPlayingFrame.marqueeOffset(contentWidth: 60, windowWidth: 60, elapsed: 2), 0)
    }

    func testClockFormatting() {
        XCTAssertEqual(NowPlayingFrame.formatClock(147.46), "2:27")
        XCTAssertEqual(NowPlayingFrame.formatClock(0), "0:00")
        XCTAssertEqual(NowPlayingFrame.formatClock(-3), "0:00")
        XCTAssertEqual(NowPlayingFrame.formatClock(3725), "62:05")
    }

    func testPositionExtrapolatesWhilePlayingAndHoldsWhilePaused() {
        let playing = track(elapsed: 10)
        XCTAssertEqual(playing.position(at: Date(timeIntervalSince1970: 1005)), 15, accuracy: 0.001)
        XCTAssertEqual(playing.position(at: Date(timeIntervalSince1970: 5000)), 100, accuracy: 0.001) // clamped
        let paused = track(elapsed: 10, rate: 0)
        XCTAssertEqual(paused.position(at: Date(timeIntervalSince1970: 1005)), 10, accuracy: 0.001)
    }

    func testArtworkIsDrawnTopLeftAndTheGapStaysBlank() {
        let art = [Bool](repeating: true, count: 64 * 64)
        let scene = NowPlayingFrame.scene(for: track(artwork: art), at: Date(timeIntervalSince1970: 1000), sinceStart: 0)
        XCTAssertEqual(scene.pixels.count, 128 * 64)
        XCTAssertTrue(lit(scene, x: 0, y: 0))
        XCTAssertTrue(lit(scene, x: 63, y: 63))
        for x in 64..<NowPlayingFrame.textX { for y in 0..<64 { XCTAssertFalse(lit(scene, x: x, y: y)) } }
    }

    func testMissingArtworkLeavesTheLeftSideBlank() {
        let scene = NowPlayingFrame.scene(for: track(), at: Date(timeIntervalSince1970: 1000), sinceStart: 0)
        for x in 0..<NowPlayingFrame.textX { for y in 0..<64 { XCTAssertFalse(lit(scene, x: x, y: y)) } }
    }

    func testProgressBarFillMatchesPosition() {
        // Halfway through: the 58px interior is filled for floor(58 * 0.5) = 29 columns.
        let scene = NowPlayingFrame.scene(for: track(duration: 100, elapsed: 50),
                                          at: Date(timeIntervalSince1970: 1000), sinceStart: 0)
        let first = NowPlayingFrame.textX + 1
        XCTAssertTrue(lit(scene, x: first, y: 59))
        XCTAssertTrue(lit(scene, x: first + 28, y: 59))
        XCTAssertFalse(lit(scene, x: first + 29, y: 59))
        XCTAssertTrue(lit(scene, x: NowPlayingFrame.textX, y: 59))   // outline
        XCTAssertTrue(lit(scene, x: 127, y: 59))
    }

    func testLongTextScrollsWithinTheColumnWithoutBleedingIntoTheArtwork() {
        let long = track(title: String(repeating: "W", count: 30))
        let held = NowPlayingFrame.scene(for: long, at: Date(timeIntervalSince1970: 1000), sinceStart: 0)
        let scrolled = NowPlayingFrame.scene(for: long, at: Date(timeIntervalSince1970: 1000), sinceStart: 4)
        XCTAssertNotEqual(held.pixels, scrolled.pixels)
        for scene in [held, scrolled] {
            for x in 0..<NowPlayingFrame.textX { for y in 0..<64 { XCTAssertFalse(lit(scene, x: x, y: y)) } }
        }
    }

    func testRefreshTimingFollowsTheDisplayedSecondOrTheScrollFrame() {
        // Position 50.25s at rate 1: the next whole second is 0.75s away.
        let still = NowPlayingFrame.scene(for: track(elapsed: 50.25), at: Date(timeIntervalSince1970: 1000), sinceStart: 0)
        XCTAssertEqual(still.refreshAfter, 0.75, accuracy: 0.001)
        let scrolling = NowPlayingFrame.scene(for: track(title: String(repeating: "W", count: 30), elapsed: 50.25),
                                              at: Date(timeIntervalSince1970: 1000), sinceStart: 0)
        XCTAssertEqual(scrolling.refreshAfter, NowPlayingFrame.frameInterval, accuracy: 0.001)
    }
}

final class NowPlayingStreamStateTests: XCTestCase {
    private func message(diff: Bool, _ payload: [String: Any]) -> [String: Any] {
        ["type": "data", "diff": diff, "payload": payload]
    }

    private let base: [String: Any] = [
        "bundleIdentifier": "com.google.Chrome", "playing": true, "title": "Song", "artist": "Artist",
        "album": "Album", "durationMicros": 200_000_000, "elapsedTimeMicros": 10_500_000,
        "timestampEpochMicros": 1_000_000_000, "playbackRate": 1
    ]

    func testEmptyPayloadMeansNothingIsPlaying() {
        var state = NowPlayingStreamState { _ in nil }
        XCTAssertNil(state.track)
        state.apply(message(diff: false, [:]))
        XCTAssertNil(state.track)
    }

    func testFullPayloadBuildsTheTrack() throws {
        var state = NowPlayingStreamState { _ in nil }
        XCTAssertTrue(state.apply(message(diff: false, base)))
        let track = try XCTUnwrap(state.track)
        XCTAssertEqual(track.title, "Song")
        XCTAssertEqual(track.duration, 200, accuracy: 0.001)
        XCTAssertEqual(track.elapsed, 10.5, accuracy: 0.001)
        XCTAssertEqual(track.anchor.timeIntervalSince1970, 1000, accuracy: 0.001)
        XCTAssertTrue(track.isPlaying)
    }

    func testDiffsMergeAndNullRemovesAKey() throws {
        var state = NowPlayingStreamState { _ in nil }
        state.apply(message(diff: false, base))
        state.apply(message(diff: true, ["playing": false, "playbackRate": 0, "album": NSNull()]))
        let track = try XCTUnwrap(state.track)
        XCTAssertFalse(track.isPlaying)
        XCTAssertEqual(track.rate, 0)
        XCTAssertEqual(track.album, "")
        XCTAssertEqual(track.title, "Song") // untouched by the diff
        state.apply(message(diff: true, ["title": NSNull()]))
        XCTAssertNil(state.track) // no title means nothing valid to show
    }

    func testIgnoresMessagesThatAreNotData() {
        var state = NowPlayingStreamState { _ in nil }
        XCTAssertFalse(state.apply(["type": "other"]))
        XCTAssertFalse(state.apply(["type": "data"]))
    }

    func testIdentitySurvivesPauseButNotTrackChange() throws {
        var state = NowPlayingStreamState { _ in nil }
        state.apply(message(diff: false, base))
        let playing = try XCTUnwrap(state.track)
        state.apply(message(diff: true, ["playing": false, "playbackRate": 0]))
        XCTAssertEqual(try XCTUnwrap(state.track).identity, playing.identity)
        state.apply(message(diff: true, ["title": "Another"]))
        XCTAssertNotEqual(try XCTUnwrap(state.track).identity, playing.identity)
    }

    func testArtworkIsOnlyDecodedWhenItsBase64Changes() throws {
        var decodes = 0
        var state = NowPlayingStreamState { _ in decodes += 1; return [true] }
        let first = Data("first".utf8).base64EncodedString()
        state.apply(message(diff: false, base.merging(["artworkData": first]) { $1 }))
        XCTAssertEqual(decodes, 1)
        // Repeated full payloads and unrelated diffs reuse the cached bitmap.
        state.apply(message(diff: false, base.merging(["artworkData": first]) { $1 }))
        state.apply(message(diff: true, ["elapsedTimeMicros": 20_000_000]))
        XCTAssertEqual(decodes, 1)
        XCTAssertEqual(state.track?.artwork, [true])
        state.apply(message(diff: true, ["artworkData": Data("second".utf8).base64EncodedString()]))
        XCTAssertEqual(decodes, 2)
        state.apply(message(diff: true, ["artworkData": NSNull()]))
        XCTAssertNil(state.track?.artwork)
    }
}

final class ArtworkDitherTests: XCTestCase {
    private func pngData(size: Int, leftGray: UInt8, rightGray: UInt8) throws -> Data {
        var pixels = [UInt8](repeating: 0, count: size * size)
        for y in 0..<size { for x in 0..<size { pixels[y * size + x] = x < size / 2 ? leftGray : rightGray } }
        let image = try XCTUnwrap(pixels.withUnsafeMutableBytes { buffer in
            CGContext(data: buffer.baseAddress, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size,
                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)?.makeImage()
        })
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    func testDarkAndLightHalvesBecomeUnlitAndLit() throws {
        let bitmap = try XCTUnwrap(ArtworkDither.bitmap(from: pngData(size: 120, leftGray: 0, rightGray: 255), size: 64))
        XCTAssertEqual(bitmap.count, 64 * 64)
        XCTAssertFalse(bitmap[32 * 64 + 5])
        XCTAssertTrue(bitmap[32 * 64 + 58])
    }

    func testNonSquareImagesFillTheSquare() throws {
        // Aspect fill must not leave letterbox bars: every row has both halves.
        let bitmap = try XCTUnwrap(ArtworkDither.bitmap(from: pngData(size: 120, leftGray: 0, rightGray: 255), size: 32))
        for y in [0, 15, 31] {
            XCTAssertFalse(bitmap[y * 32 + 2])
            XCTAssertTrue(bitmap[y * 32 + 29])
        }
    }

    func testGarbageIsRejected() {
        XCTAssertNil(ArtworkDither.bitmap(from: Data("not an image".utf8), size: 64))
    }
}
