import Foundation

/// What the system says is playing, reduced to what the SteelSeries display needs.
struct NowPlayingTrack: Equatable {
    var title: String
    var artist: String
    var album: String
    var duration: TimeInterval
    /// Playback position at `anchor`.
    var elapsed: TimeInterval
    var anchor: Date
    /// 1 while playing normally, 0 while paused.
    var rate: Double
    var isPlaying: Bool
    /// Pre-dithered artwork, `NowPlayingFrame.artSize` squared, row-major.
    var artwork: [Bool]?

    /// Changes when the media changes, but not on pause/resume or seeking.
    var identity: String { "\(title)\u{1F}\(artist)\u{1F}\(album)" }

    /// Playback position at `date`, extrapolated from the last report.
    func position(at date: Date) -> TimeInterval {
        let position = elapsed + max(0, date.timeIntervalSince(anchor)) * rate
        return duration > 0 ? min(duration, max(0, position)) : max(0, position)
    }
}

/// Folds `mediaremote-adapter stream` messages into the current now-playing
/// state. With diffing on, the adapter sends only changed keys (a key that
/// vanished arrives as null), and artwork only when it changes, so this keeps
/// the merged payload and decodes artwork only when its base64 actually changes.
struct NowPlayingStreamState {
    private var payload: [String: Any] = [:]
    private var artworkSource: String?
    private var artwork: [Bool]?
    private let decodeArtwork: (Data) -> [Bool]?

    init(decodeArtwork: @escaping (Data) -> [Bool]?) {
        self.decodeArtwork = decodeArtwork
    }

    /// Applies one decoded stream line. Returns false if it was not a data message.
    @discardableResult
    mutating func apply(_ message: [String: Any]) -> Bool {
        guard message["type"] as? String == "data",
              let update = message["payload"] as? [String: Any] else { return false }

        if message["diff"] as? Bool == true {
            for (key, value) in update {
                if value is NSNull { payload.removeValue(forKey: key) } else { payload[key] = value }
            }
        } else {
            payload = update.filter { !($0.value is NSNull) }
        }

        guard let source = payload["artworkData"] as? String else {
            artworkSource = nil
            artwork = nil
            return true
        }
        if source != artworkSource {
            artworkSource = source
            artwork = Data(base64Encoded: source).flatMap(decodeArtwork)
        }
        return true
    }

    /// Nil when nothing is playing or paused (no player reporting, or no title).
    var track: NowPlayingTrack? {
        guard let title = payload["title"] as? String, !title.isEmpty,
              let isPlaying = (payload["playing"] as? NSNumber)?.boolValue else { return nil }

        func seconds(_ key: String) -> Double? { (payload[key] as? NSNumber).map { $0.doubleValue / 1_000_000 } }
        let rate = (payload["playbackRate"] as? NSNumber)?.doubleValue ?? (isPlaying ? 1 : 0)
        return NowPlayingTrack(
            title: title,
            artist: payload["artist"] as? String ?? "",
            album: payload["album"] as? String ?? "",
            duration: seconds("durationMicros") ?? 0,
            elapsed: seconds("elapsedTimeMicros") ?? 0,
            anchor: seconds("timestampEpochMicros").map { Date(timeIntervalSince1970: $0) } ?? Date(),
            rate: rate,
            isPlaying: isPlaying,
            artwork: artwork)
    }
}
