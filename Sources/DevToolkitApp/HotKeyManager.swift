import Carbon.HIToolbox
import AppKit

/// Registers a single system-wide keyboard shortcut via the classic Carbon
/// Event Manager (`RegisterEventHotKey`). This requires no Accessibility or
/// Input Monitoring permission at all - it's the same mechanism used by
/// most third-party menu-bar hotkey utilities.
final class HotKeyManager {
    private static let signature: OSType = 0x44544B54 // 'DTKT'
    /// Each instance installs its own handler on the same shared application
    /// event target, so Carbon dispatches every hotkey-pressed event to every
    /// installed handler - the id must be unique per instance (not a shared
    /// constant) so each handler can tell whether the fired event was its
    /// own hotkey or a different instance's.
    private static var nextHotKeyID: UInt32 = 1
    private let hotKeyID: UInt32

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private let onTrigger: () -> Void

    /// - Parameters:
    ///   - keyCode: a `kVK_*` virtual key code (default: Space).
    ///   - modifiers: a Carbon modifier mask, e.g. `optionKey` (default).
    init?(keyCode: UInt32 = UInt32(kVK_Space), modifiers: UInt32 = UInt32(optionKey), onTrigger: @escaping () -> Void) {
        self.onTrigger = onTrigger
        self.hotKeyID = HotKeyManager.nextHotKeyID
        HotKeyManager.nextHotKeyID += 1

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, eventRef, userData -> OSStatus in
                // Multiple HotKeyManager instances each install a handler on
                // the same shared application event target, forming a
                // chain. Returning `noErr` tells Carbon "fully handled, stop
                // propagating" - so any early-exit for an event that isn't
                // this instance's own hotkey must return `eventNotHandledErr`
                // instead, or it silently swallows events meant for a
                // different (e.g. more recently installed) handler further
                // down the chain.
                guard let userData, let eventRef else { return OSStatus(eventNotHandledErr) }
                var hkID = EventHotKeyID()
                let status = GetEventParameter(
                    eventRef,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hkID
                )
                guard status == noErr else { return OSStatus(eventNotHandledErr) }
                let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
                guard hkID.id == manager.hotKeyID else { return OSStatus(eventNotHandledErr) }
                manager.onTrigger()
                return noErr
            },
            1,
            &eventType,
            selfPtr,
            &eventHandler
        )
        guard handlerStatus == noErr else { return nil }

        let hkID = EventHotKeyID(signature: HotKeyManager.signature, id: hotKeyID)
        let registerStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            hkID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard registerStatus == noErr else {
            if let eventHandler { RemoveEventHandler(eventHandler) }
            return nil
        }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }
}
