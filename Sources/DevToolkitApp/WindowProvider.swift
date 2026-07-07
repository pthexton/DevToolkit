/// Something that can enumerate deep, sub-app-level switch targets (e.g. a
/// browser's tabs) via that app's own AppleScript dictionary. Implement one
/// per scriptable app you want tab/window-level precision for; everything
/// else falls back to `RunningAppsProvider`'s plain app-level activation.
protocol WindowProvider {
    /// Bundle identifiers this provider claims deep integration for. Running
    /// apps with these bundle ids are excluded from the generic
    /// `RunningAppsProvider` fallback list so they don't show up twice.
    static var supportedBundleIDs: Set<String> { get }

    /// Whether this provider currently has anything to contribute (i.e. its
    /// app is running). Cheap; safe to call on the main thread.
    func isAvailable() -> Bool

    /// Fetches current items. May block (e.g. on `NSAppleScript` execution) -
    /// always call this off the main thread.
    func fetchItems() -> [SwitchItem]
}
