import AppKit
import OSLog

private let log = Logger(subsystem: "com.beyondtrust.devtoolkit", category: "relocate")

/// Reads and sets window bounds with raw Apple Events addressed to a single
/// process by pid. `tell application id "..."` resolves a bundle id to just
/// one process, which strands the rest when several processes share a bundle
/// id (every `rockit run` is its own process). Blocking: call off the main
/// thread.
enum AppleEventWindows {
    /// `{left, top, right, bottom}` of every window, in Apple Event
    /// (top-left origin) coordinates. nil when the app could not be read at
    /// all (automation permission denied, no window support).
    static func boundsOfEveryWindow(pid: pid_t) -> [CGRect?]? {
        var all = fourCC("all ") // native byte order, unlike most AE data
        guard let everything = NSAppleEventDescriptor(descriptorType: typeAbsoluteOrdinal, bytes: &all, length: 4) else { return nil }
        let windows = specifier(want: "cwin", container: .null(), form: "indx", selector: everything)
        let bounds = specifier(want: "prop", container: windows, form: "prop",
                               selector: NSAppleEventDescriptor(typeCode: fourCC("pbnd")))
        guard let reply = send(pid: pid, eventID: "getd", direct: bounds, data: nil) else { return nil }
        guard let result = reply.paramDescriptor(forKeyword: fourCC("----")) else { return nil }
        return decodeBounds(result)
    }

    /// Sets window `index` (1-based) to `rect`. Returns false on any error.
    static func setBounds(pid: pid_t, windowIndex index: Int, to rect: CGRect) -> Bool {
        let window = specifier(want: "cwin", container: .null(), form: "indx",
                               selector: NSAppleEventDescriptor(int32: Int32(index)))
        let bounds = specifier(want: "prop", container: window, form: "prop",
                               selector: NSAppleEventDescriptor(typeCode: fourCC("pbnd")))
        let value = NSAppleEventDescriptor.list()
        for (i, v) in WindowGeometry.appleEventBounds(rect).enumerated() {
            value.insert(NSAppleEventDescriptor(int32: Int32(v)), at: i + 1)
        }
        return send(pid: pid, eventID: "setd", direct: bounds, data: value) != nil
    }

    /// Decodes a `bounds of every window` reply. A window's bounds arrive
    /// either as a `qdrt` (Int16 top, left, bottom, right) or as a list of
    /// four integers (left, top, right, bottom). An entry that cannot be
    /// decoded stays in place as nil so 1-based window indices line up.
    static func decodeBounds(_ reply: NSAppleEventDescriptor) -> [CGRect?] {
        if reply.descriptorType == typeQDRectangle { return [rect(fromQuickDraw: reply)] }
        guard reply.numberOfItems > 0 else { return [] }
        let items = (1...reply.numberOfItems).compactMap { reply.atIndex($0) }
        // A bare list of numbers is one window's bounds, not a list of windows.
        if items.count == 4, items.allSatisfy({ $0.numberOfItems == 0 && $0.descriptorType != typeQDRectangle }) {
            return [rect(fromIntegers: reply)]
        }
        return items.map { item in
            item.descriptorType == typeQDRectangle ? rect(fromQuickDraw: item) : rect(fromIntegers: item)
        }
    }

    // MARK: - Event plumbing

    private static func fourCC(_ s: String) -> OSType { s.utf8.reduce(0) { ($0 << 8) | OSType($1) } }

    private static func specifier(want: String, container: NSAppleEventDescriptor,
                                  form: String, selector: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        let record = NSAppleEventDescriptor.record()
        record.setDescriptor(NSAppleEventDescriptor(typeCode: fourCC(want)), forKeyword: fourCC("want"))
        record.setDescriptor(container, forKeyword: fourCC("from"))
        record.setDescriptor(NSAppleEventDescriptor(enumCode: fourCC(form)), forKeyword: fourCC("form"))
        record.setDescriptor(selector, forKeyword: fourCC("seld"))
        // The coercion to an object specifier cannot fail for a well-formed record.
        return record.coerce(toDescriptorType: typeObjectSpecifier) ?? record
    }

    private static func send(pid: pid_t, eventID: String, direct: NSAppleEventDescriptor,
                             data: NSAppleEventDescriptor?) -> NSAppleEventDescriptor? {
        let event = NSAppleEventDescriptor(eventClass: fourCC("core"), eventID: fourCC(eventID),
                                           targetDescriptor: NSAppleEventDescriptor(processIdentifier: pid),
                                           returnID: AEReturnID(kAutoGenerateReturnID),
                                           transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(direct, forKeyword: fourCC("----"))
        if let data { event.setParam(data, forKeyword: fourCC("data")) }
        do {
            let reply = try event.sendEvent(options: [.waitForReply], timeout: 10)
            if let error = reply.paramDescriptor(forKeyword: fourCC("errn")), error.int32Value != 0 {
                log.error("Apple Event \(eventID, privacy: .public) to pid \(pid) failed: \(error.int32Value)")
                return nil
            }
            return reply
        } catch {
            log.error("Apple Event \(eventID, privacy: .public) to pid \(pid) not sent: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private static func rect(fromQuickDraw d: NSAppleEventDescriptor) -> CGRect? {
        let v = d.data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        guard v.count == 4 else { return nil }
        return WindowGeometry.rect(fromAppleEventBounds: [Int(v[1]), Int(v[0]), Int(v[3]), Int(v[2])])
    }

    private static func rect(fromIntegers d: NSAppleEventDescriptor) -> CGRect? {
        guard d.numberOfItems == 4 else { return nil }
        return WindowGeometry.rect(fromAppleEventBounds: (1...4).map { Int(d.atIndex($0)?.int32Value ?? 0) })
    }
}
