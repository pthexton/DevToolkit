import Foundation
import AppKit
import IOKit.hid
import OSLog

private let log = Logger(subsystem: "com.beyondtrust.devtoolkit", category: "litra-glow")

/// What DevToolkit knows about the light. The values are nil until the light
/// has answered a query.
struct LitraGlowState: Equatable {
    var isConnected = false
    var isOn: Bool?
    var lumen: UInt16?
    var kelvin: UInt16?
}

/// Controls a Logitech Litra Glow over raw HID (IOKit only, no Logitech
/// software involved). The wire format is documented on `LitraProtocol`.
///
/// Power and brightness follow the menu. Colour temperature is not offered in
/// the menu; instead, when a `pinnedKelvin` is given, the light is held at it:
/// whenever the light reports a different temperature (on connect, on wake,
/// when a menu opens, or when another app such as Logi Options+ changes it),
/// the pinned value is written back. Reassertions are spaced at least
/// `reassertInterval` apart, so if another program keeps changing it the two
/// do not fight in a tight loop; the light just settles back a few seconds
/// later.
///
/// All mutable state is confined to a private serial queue, which also services
/// the IOHID callbacks, so no locking is needed. The device is opened
/// non-exclusively, so Logi Options+ can keep running alongside; its replies
/// and the light's own button notifications arrive here too and keep the
/// state current.
///
/// The light answers one request at a time and silently drops a request sent
/// while another is outstanding (measured: back-to-back power and brightness
/// queries get only the second answered). Requests therefore go through an
/// outbox: one is in flight until its reply arrives or `replyTimeout` passes.
/// State changes only when the light reports it, never optimistically.
final class LitraGlow: @unchecked Sendable {
    private static let replyTimeout: TimeInterval = 0.3
    private static let reassertInterval: TimeInterval = 5

    private let queue = DispatchQueue(label: "com.beyondtrust.devtoolkit.litra-glow", qos: .userInitiated)
    private let onChange: @Sendable (LitraGlowState) -> Void
    private let pinnedKelvin: UInt16?

    // Queue-confined state.
    private var running = false
    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private var wakeObserver: NSObjectProtocol?
    private var outbox: [[UInt8]] = []
    private var inFlight: [UInt8]?
    private var inFlightTimeout: DispatchWorkItem?
    private var lastReassert = Date.distantPast
    private var reassertPending = false
    private var state = LitraGlowState() {
        didSet { if state != oldValue { onChange(state) } }
    }

    /// `pinnedKelvin`, if given, is the colour temperature to hold the light
    /// at; nil leaves temperature alone. `onChange` runs on the private queue.
    init(pinnedKelvin: UInt16? = nil, onChange: @escaping @Sendable (LitraGlowState) -> Void) {
        self.pinnedKelvin = pinnedKelvin
        self.onChange = onChange
    }

    /// Starts watching for the light. Idempotent. Safe from any thread.
    func start() { queue.sync { startOnQueue() } }

    /// Releases the light. Leaves it in whatever state it is in. Idempotent.
    func stop() { queue.sync { stopOnQueue() } }

    /// Asks the light for its current power, brightness and colour temperature
    /// (and so also reasserts the pinned temperature if it has drifted).
    func refresh() { queue.async { self.query() } }

    func setOn(_ on: Bool) {
        queue.async { self.enqueue(LitraProtocol.setPower(on)) }
    }

    func setBrightness(percent: Int) {
        queue.async {
            self.enqueue(LitraProtocol.setBrightness(lumen: LitraProtocol.lumen(forPercent: percent)))
        }
    }

    // MARK: - Lifecycle (queue only)

    private func startOnQueue() {
        guard !running else { return }

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDVendorIDKey: LitraProtocol.vendorID,
            kIOHIDProductIDKey: LitraProtocol.glowProductID,
            kIOHIDDeviceUsagePageKey: LitraProtocol.usagePage
        ] as CFDictionary)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<LitraGlow>.fromOpaque(context).takeUnretainedValue().attach(device)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<LitraGlow>.fromOpaque(context).takeUnretainedValue().detach(device)
        }, context)
        // Registered on the manager, before activation: IOKit traps if an input
        // callback is registered on a device that a dispatch-queue manager has
        // already activated, which is every device the matching callback sees.
        IOHIDManagerRegisterInputReportCallback(manager, { context, result, sender, _, _, report, length in
            guard let context, let sender, result == kIOReturnSuccess else { return }
            let device = Unmanaged<IOHIDDevice>.fromOpaque(sender).takeUnretainedValue()
            let bytes = Array(UnsafeBufferPointer(start: report, count: length))
            Unmanaged<LitraGlow>.fromOpaque(context).takeUnretainedValue().received(bytes, from: device)
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

        // The light may have been changed by hand while the Mac slept.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: nil
        ) { [weak self] _ in self?.refresh() }

        running = true
        IOHIDManagerActivate(manager)
        log.notice("Watching for Litra Glow")
    }

    private func stopOnQueue() {
        guard running else { return }
        running = false

        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        if let device { release(device) }
        if let manager {
            IOHIDManagerCancel(manager)
            self.manager = nil
        }
        state = LitraGlowState()
    }

    // MARK: - Device events (queue only)

    private func attach(_ device: IOHIDDevice) {
        guard running, self.device == nil else { return }

        let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            log.error("Could not open Litra Glow: \(result, privacy: .public)")
            return
        }

        self.device = device
        state = LitraGlowState(isConnected: true)
        log.notice("Litra Glow connected")
        query()
    }

    private func detach(_ device: IOHIDDevice) {
        guard device == self.device else { return }
        release(device)
        state = LitraGlowState()
        log.notice("Litra Glow disconnected")
    }

    private func release(_ device: IOHIDDevice) {
        outbox.removeAll()
        finishInFlight()
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        self.device = nil
    }

    private func received(_ report: [UInt8], from sender: IOHIDDevice) {
        guard sender == device else { return }
        switch LitraProtocol.parse(report) {
        case .power(let on)?: state.isOn = on
        case .brightness(let lumen)?: state.lumen = lumen
        case .temperature(let kelvin)?:
            state.kelvin = kelvin
            holdTemperature()
        case nil: break
        }
        if let inFlight, LitraProtocol.isReply(report, to: inFlight) {
            finishInFlight()
            pump()
        }
    }

    // MARK: - Writing (queue only)

    private func query() {
        enqueue(LitraProtocol.queryPower())
        enqueue(LitraProtocol.queryBrightness())
        if pinnedKelvin != nil { enqueue(LitraProtocol.queryTemperature()) }
    }

    /// Writes the pinned temperature back if the light reports another one,
    /// at most once per `reassertInterval`; a change inside that window is
    /// corrected when the window ends.
    private func holdTemperature() {
        guard let pinnedKelvin, let kelvin = state.kelvin, kelvin != pinnedKelvin, device != nil else { return }
        let wait = lastReassert.addingTimeInterval(Self.reassertInterval).timeIntervalSinceNow
        if wait > 0 {
            guard !reassertPending else { return }
            reassertPending = true
            queue.asyncAfter(deadline: .now() + wait) { [weak self] in
                self?.reassertPending = false
                self?.holdTemperature()
            }
            return
        }
        lastReassert = Date()
        log.notice("Litra Glow is at \(kelvin, privacy: .public) K; restoring \(pinnedKelvin, privacy: .public) K")
        enqueue(LitraProtocol.setTemperature(kelvin: pinnedKelvin))
    }

    private func enqueue(_ request: [UInt8]) {
        guard device != nil else { return }
        // A newer identical request (a repeated refresh, or a second brightness
        // pick before the first applied) supersedes a queued one.
        outbox.removeAll { $0[3] == request[3] }
        outbox.append(request)
        pump()
    }

    /// Sends the next queued request if none is in flight.
    private func pump() {
        guard inFlight == nil, let device, !outbox.isEmpty else { return }
        let request = outbox.removeFirst()

        // The report ID is the first byte of the buffer, as IOKit expects for
        // numbered reports.
        let result = request.withUnsafeBufferPointer {
            IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(request[0]), $0.baseAddress!, $0.count)
        }
        guard result == kIOReturnSuccess else {
            log.error("Litra Glow write failed: \(result, privacy: .public)")
            outbox.removeAll()
            return
        }

        inFlight = request
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.inFlight == request else { return }
            log.debug("No reply from Litra Glow; sending next request")
            self.finishInFlight()
            self.pump()
        }
        inFlightTimeout = timeout
        queue.asyncAfter(deadline: .now() + Self.replyTimeout, execute: timeout)
    }

    private func finishInFlight() {
        inFlightTimeout?.cancel()
        inFlightTimeout = nil
        inFlight = nil
    }
}

/// Main-actor wrapper the menu binds to. Re-queries the light each time a menu
/// opens, so changes made with the light's buttons or another app show up.
@MainActor
final class LitraGlowFeature: ObservableObject {
    /// Brightness choices offered in the menu, in percent.
    static let brightnessSteps = Array(stride(from: 10, through: 100, by: 10))

    /// The colour temperature the light is held at: 6500 K, the Glow's
    /// coolest setting, which is what it was set to when this was written
    /// (read from the light, Nov 2026). Set to nil to leave temperature to
    /// Logi Options+ or the light's buttons. To make it user-selectable, see
    /// the "Colour" section on `LitraProtocol`.
    static let pinnedTemperature: UInt16? = 6500

    @Published private(set) var state = LitraGlowState()

    private var light: LitraGlow!
    private var menuObserver: NSObjectProtocol?

    init() {
        light = LitraGlow(pinnedKelvin: Self.pinnedTemperature) { [weak self] state in
            Task { @MainActor in self?.state = state }
        }
    }

    var brightnessPercent: Int? {
        state.lumen.map(LitraProtocol.percent(forLumen:))
    }

    func setOn(_ on: Bool) { light.setOn(on) }

    func setBrightness(percent: Int) { light.setBrightness(percent: percent) }

    /// Call once the app has decided it is the canonical instance.
    func start() {
        light.start()
        menuObserver = NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.light.refresh() }
        }
    }

    /// Call on app termination.
    func shutdown() {
        if let menuObserver { NotificationCenter.default.removeObserver(menuObserver) }
        light.stop()
    }
}
