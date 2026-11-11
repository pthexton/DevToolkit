import Foundation
import AppKit
import IOKit.hid
import OSLog

private let log = Logger(subsystem: "com.beyondtrust.devtoolkit", category: "steelseries-clock")

/// Draws a clock on the OLED of a SteelSeries Arctis Nova Pro Wireless base
/// station over raw HID (IOKit only, no SteelSeries software involved).
///
/// All mutable state is confined to a private serial queue. That queue also
/// services the IOHID callbacks and the refresh timer, so no locking is needed.
///
/// Timing: the refresh timer is a `.strict` GCD timer armed with a wall-clock
/// deadline (`DispatchWallTime`) at the next minute boundary with zero leeway.
/// Wall time (rather than monotonic time) keeps it correct across sleep and
/// manual clock or time zone changes. The frame is rendered for the deadline
/// instant, not for "whenever the timer happened to run", so a timer that fires
/// a hair early can never draw the previous minute.
final class SteelSeriesClock: @unchecked Sendable {
    private static let vendorID = 0x1038
    private static let productID = 0x12e0
    private static let oledUsagePage = 0xffc0

    private let queue = DispatchQueue(label: "com.beyondtrust.devtoolkit.steelseries-clock", qos: .userInitiated)

    // Queue-confined state.
    private var running = false
    private var manager: IOHIDManager?
    private var devices: [UInt64: IOHIDDevice] = [:]
    private var timer: DispatchSourceTimer?
    private var target = Date()
    private var wakeObserver: NSObjectProtocol?

    // Now playing (queue-confined). While something is playing the display
    // shows it; otherwise (paused, stopped, nothing reporting) it shows the clock.
    private var nowPlayingEnabled = true
    private var monitor: NowPlayingMonitor?
    private var nowPlaying: NowPlayingTrack?
    private var sceneStart = Date()
    /// The last frame sent, so identical frames (marquee holds) are not re-sent.
    private var lastPixels: [Bool]?
    private var lastWrite = Date.distantPast
    /// Frames are re-sent at least this often even if unchanged, in case the
    /// device reverts to its own UI when left idle.
    private static let heartbeat: TimeInterval = 5

    /// Starts watching for the base station. Idempotent. Safe from any thread.
    func start() {
        queue.sync { startOnQueue() }
    }

    /// Restores the factory display, releases the device and stops all timers.
    /// Synchronous so it completes before the app exits. Idempotent.
    func stop() {
        queue.sync { stopOnQueue() }
    }

    /// Turns the now-playing screen on or off. Safe from any thread.
    func setNowPlayingEnabled(_ enabled: Bool) {
        queue.sync {
            nowPlayingEnabled = enabled
            updateMonitor()
        }
    }

    // MARK: - Now playing (queue only)

    private func updateMonitor() {
        if running, nowPlayingEnabled {
            guard monitor == nil else { return }
            guard let adapter = NowPlayingMonitor.Adapter.bundled() else {
                log.error("MediaRemote adapter is not bundled; now playing disabled")
                return
            }
            let monitor = NowPlayingMonitor(adapter: adapter) { [weak self] track in
                self?.queue.async { self?.nowPlayingChanged(track) }
            }
            self.monitor = monitor
            monitor.start()
        } else if let monitor {
            self.monitor = nil
            monitor.stop()
            nowPlaying = nil
            refreshAll()
        }
    }

    private func nowPlayingChanged(_ track: NowPlayingTrack?) {
        guard running, monitor != nil else { return }
        let wasShowing = nowPlaying?.isPlaying == true
        let isShowing = track?.isPlaying == true
        if isShowing, !wasShowing || track?.identity != nowPlaying?.identity {
            sceneStart = Date() // new track or resumed: marquee starts from the beginning
        }
        nowPlaying = track
        refreshAll()
    }

    // MARK: - Lifecycle (queue only)

    private func startOnQueue() {
        guard !running else { return }

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDVendorIDKey: Self.vendorID,
            kIOHIDProductIDKey: Self.productID
        ] as CFDictionary)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<SteelSeriesClock>.fromOpaque(context).takeUnretainedValue().attach(device)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<SteelSeriesClock>.fromOpaque(context).takeUnretainedValue().detach(device)
        }, context)

        IOHIDManagerSetDispatchQueue(manager, queue)
        // Retain the manager until cancellation has fully completed.
        IOHIDManagerSetCancelHandler(manager) { _ = manager }

        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            log.error("Cannot open HID manager: \(result, privacy: .public)")
            return
        }
        self.manager = manager

        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        timer.setEventHandler { [weak self] in self?.refreshAll(fromTimer: true) }
        timer.schedule(wallDeadline: .distantFuture, repeating: .never, leeway: .nanoseconds(0))
        timer.resume()
        self.timer = timer

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            self?.queue.async {
                self?.lastPixels = nil
                self?.refreshAll()
            }
        }

        // All state must be ready before activation: the matching callback for
        // an already-connected device can run as soon as the manager is active.
        running = true
        updateMonitor()
        IOHIDManagerActivate(manager)
        log.notice("Clock started; waiting for base station")
    }

    private func stopOnQueue() {
        guard running else { return }
        running = false
        updateMonitor() // stops the now-playing adapter
        nowPlaying = nil
        lastPixels = nil

        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        timer?.cancel()
        timer = nil

        for device in devices.values {
            var report = [UInt8](repeating: 0, count: 64)
            report[0] = 6
            report[1] = 0x95 // hand the display back to the factory UI
            let result = report.withUnsafeBufferPointer {
                IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 6, $0.baseAddress!, $0.count)
            }
            if result != kIOReturnSuccess {
                log.error("Restoring factory UI failed: \(result, privacy: .public)")
            }
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        devices.removeAll()

        if let manager {
            IOHIDManagerCancel(manager)
            self.manager = nil
        }
        log.notice("Clock stopped")
    }

    // MARK: - Device events (queue only)

    private func number(_ device: IOHIDDevice, _ key: String) -> Int {
        (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue ?? -1
    }

    private func identifier(_ device: IOHIDDevice) -> UInt64 {
        var id: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device), &id)
        return id
    }

    private func attach(_ device: IOHIDDevice) {
        log.debug("""
            HID match: product \(self.number(device, kIOHIDProductIDKey), privacy: .public) \
            usagePage \(self.number(device, kIOHIDPrimaryUsagePageKey), privacy: .public) \
            maxFeature \(self.number(device, kIOHIDMaxFeatureReportSizeKey), privacy: .public)
            """)
        // Only the vendor OLED collection (not the media keys or other interfaces).
        guard running,
              number(device, kIOHIDProductIDKey) == Self.productID,
              number(device, kIOHIDPrimaryUsagePageKey) == Self.oledUsagePage,
              number(device, kIOHIDMaxFeatureReportSizeKey) >= 1024 else { return }
        let id = identifier(device)
        guard devices[id] == nil else { return }

        let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            log.error("Could not open OLED: \(result, privacy: .public). Another device-control app may hold it.")
            return
        }
        devices[id] = device
        log.notice("Base station connected")
        lastPixels = nil
        refreshAll()
    }

    private func detach(_ device: IOHIDDevice) {
        guard devices.removeValue(forKey: identifier(device)) != nil else { return }
        log.notice("Base station disconnected")
        if devices.isEmpty {
            timer?.schedule(wallDeadline: .distantFuture, repeating: .never, leeway: .nanoseconds(0))
        }
    }

    // MARK: - Drawing and timing (queue only)

    private func refreshAll(fromTimer: Bool = false) {
        guard running, !devices.isEmpty else { return }

        // From the timer: render for the instant it was aimed at (never earlier
        // than now), plus a tiny epsilon so floating point error can't land us
        // 1ns before the boundary and draw the old minute. From any other
        // trigger (a track change, wake) the pending deadline may be far in the
        // future, so render for the present instead.
        let renderDate = (fromTimer ? max(Date(), target) : Date()).addingTimeInterval(0.002)
        let scene: ClockFrame.Scene
        if let track = nowPlaying, track.isPlaying {
            scene = NowPlayingFrame.scene(for: track, at: renderDate, sinceStart: renderDate.timeIntervalSince(sceneStart))
        } else {
            scene = ClockFrame.scene(at: renderDate)
        }

        if scene.pixels == lastPixels, Date().timeIntervalSince(lastWrite) < Self.heartbeat {
            arm(at: renderDate.addingTimeInterval(scene.refreshAfter))
            return
        }
        let reports = ClockFrame.reports(scene.pixels)

        var failed = false
        for device in devices.values {
            for report in reports {
                let result = report.withUnsafeBufferPointer {
                    IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, 6, $0.baseAddress!, $0.count)
                }
                if result != kIOReturnSuccess {
                    log.error("Clock write failed: \(result, privacy: .public); retrying shortly")
                    failed = true
                    break
                }
            }
        }

        if failed {
            lastPixels = nil
            arm(at: Date().addingTimeInterval(2))
        } else {
            lastPixels = scene.pixels
            lastWrite = Date()
            log.debug("Displayed: \(scene.description, privacy: .public)")
            arm(at: renderDate.addingTimeInterval(scene.refreshAfter))
        }
    }

    private func arm(at date: Date) {
        target = date
        timer?.schedule(wallDeadline: DispatchWallTime(date: date), repeating: .never, leeway: .nanoseconds(0))
    }
}

private extension DispatchWallTime {
    init(date: Date) {
        let seconds = date.timeIntervalSince1970
        let whole = seconds.rounded(.down)
        self.init(timespec: timespec(tv_sec: Int(whole), tv_nsec: Int((seconds - whole) * 1_000_000_000)))
    }
}

/// Main-actor wrapper that owns the persisted on/off setting and drives
/// `SteelSeriesClock`. The menu-bar toggle binds to `isEnabled`.
@MainActor
final class SteelSeriesClockFeature: ObservableObject {
    private static let defaultsKey = "steelSeriesClockEnabled"
    private static let nowPlayingDefaultsKey = "steelSeriesNowPlayingEnabled"

    private let clock = SteelSeriesClock()

    @Published var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            UserDefaults.standard.set(isEnabled, forKey: Self.defaultsKey)
            if isEnabled { clock.start() } else { clock.stop() }
        }
    }

    /// Show what is playing instead of the clock while media is playing.
    @Published var showsNowPlaying: Bool {
        didSet {
            guard showsNowPlaying != oldValue else { return }
            UserDefaults.standard.set(showsNowPlaying, forKey: Self.nowPlayingDefaultsKey)
            clock.setNowPlayingEnabled(showsNowPlaying)
        }
    }

    init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.defaultsKey)
        showsNowPlaying = UserDefaults.standard.object(forKey: Self.nowPlayingDefaultsKey) as? Bool ?? true
        clock.setNowPlayingEnabled(showsNowPlaying)
    }

    /// Call once the app has decided it is the canonical instance.
    func startIfEnabled() {
        if isEnabled { clock.start() }
    }

    /// Restores the factory display. Call on app termination.
    func shutdown() {
        clock.stop()
    }
}
