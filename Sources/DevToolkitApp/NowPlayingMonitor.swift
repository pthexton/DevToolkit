import Foundation
import OSLog

private let log = Logger(subsystem: "com.beyondtrust.devtoolkit", category: "now-playing")

/// Streams system now-playing info by running the bundled mediaremote-adapter.
///
/// Apple restricts the private MediaRemote framework to Apple-signed callers
/// since macOS 15.4, so the adapter runs its helper framework inside
/// `/usr/bin/perl` (which is entitled to use it) and prints JSON lines to
/// stdout. The framework is bundled, never linked.
///
/// All state is confined to a private serial queue. `onChange` is called on
/// that queue, only when the track state actually differs, with nil when
/// nothing is reporting.
final class NowPlayingMonitor: @unchecked Sendable {
    struct Adapter {
        let script: URL
        let framework: URL

        /// The adapter files bundled into the app, or nil (e.g. `swift run`).
        static func bundled(_ bundle: Bundle = .main) -> Adapter? {
            guard let script = bundle.resourceURL?.appendingPathComponent("mediaremote-adapter.pl"),
                  let framework = bundle.privateFrameworksURL?.appendingPathComponent("MediaRemoteAdapter.framework"),
                  FileManager.default.fileExists(atPath: script.path),
                  FileManager.default.fileExists(atPath: framework.path) else { return nil }
            return Adapter(script: script, framework: framework)
        }
    }

    private let adapter: Adapter
    private let onChange: @Sendable (NowPlayingTrack?) -> Void
    private let queue = DispatchQueue(label: "com.beyondtrust.devtoolkit.now-playing", qos: .userInitiated)

    // Queue-confined state.
    private var wanted = false
    private var process: Process?
    private var buffer = Data()
    private var state = NowPlayingStreamState { ArtworkDither.bitmap(from: $0, size: NowPlayingFrame.artSize) }
    private var lastEmitted: NowPlayingTrack?
    private var restartDelay: TimeInterval = 1

    init(adapter: Adapter, onChange: @escaping @Sendable (NowPlayingTrack?) -> Void) {
        self.adapter = adapter
        self.onChange = onChange
    }

    /// Idempotent. Safe from any thread.
    func start() {
        queue.async { [self] in
            guard !wanted else { return }
            wanted = true
            launch()
        }
    }

    /// Terminates the adapter. Synchronous so no child outlives the app.
    func stop() {
        queue.sync { [self] in
            wanted = false
            terminate()
            reset()
        }
    }

    // MARK: - Process (queue only)

    private func launch() {
        guard wanted, process == nil else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        // --micros: precise timestamps. --debounce: merge bursts of updates.
        process.arguments = [adapter.script.path, adapter.framework.path, "stream", "--micros", "--debounce=100"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] finished in
            self?.queue.async { self?.didTerminate(finished) }
        }
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return } // EOF
            self?.queue.async { self?.consume(data, from: process) }
        }

        do {
            try process.run()
            self.process = process
            log.notice("Adapter started")
        } catch {
            log.error("Could not start adapter: \(error.localizedDescription, privacy: .public)")
            scheduleRestart()
        }
    }

    private func terminate() {
        guard let process else { return }
        self.process = nil
        (process.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        process.terminationHandler = nil
        if process.isRunning { process.terminate() }
    }

    private func didTerminate(_ finished: Process) {
        guard process === finished else { return } // an old child, already replaced
        log.error("Adapter exited (status \(finished.terminationStatus, privacy: .public))")
        terminate()
        reset()
        scheduleRestart()
    }

    private func scheduleRestart() {
        guard wanted else { return }
        let delay = restartDelay
        restartDelay = min(restartDelay * 2, 30)
        queue.asyncAfter(deadline: .now() + delay) { [self] in launch() }
    }

    // MARK: - Output (queue only)

    private func consume(_ data: Data, from source: Process) {
        guard process === source else { return }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            handle(line: Data(line))
        }
    }

    private func handle(line: Data) {
        guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              state.apply(message) else { return }
        restartDelay = 1 // healthy again
        emit()
    }

    private func emit() {
        let track = state.track
        guard track != lastEmitted else { return }
        lastEmitted = track
        onChange(track)
    }

    /// Forgets everything and tells the consumer nothing is playing.
    private func reset() {
        buffer.removeAll()
        state = NowPlayingStreamState { ArtworkDither.bitmap(from: $0, size: NowPlayingFrame.artSize) }
        emit()
    }
}
