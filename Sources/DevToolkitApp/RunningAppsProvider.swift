import AppKit

/// The generic fallback: every regular running app becomes a plain,
/// searchable "activate this app" result, regardless of whether it has any
/// scripting dictionary at all. This is what makes Teams, Xcode, Finder, and
/// anything else we don't specialise in still fully switchable - just with
/// app-level, not tab/window-level, precision. Activation is plain
/// `NSRunningApplication.activate`, which needs no scripting dictionary and
/// no permission whatsoever.
struct RunningAppsProvider {
    /// Bundle ids to exclude because a `WindowProvider` already contributes
    /// deep results for them (so e.g. Safari doesn't show up twice).
    private let excludedBundleIDs: Set<String>

    init(excludedBundleIDs: Set<String>) {
        self.excludedBundleIDs = excludedBundleIDs
    }

    func fetchItems() -> [SwitchItem] {
        let selfBundleID = Bundle.main.bundleIdentifier
        return NSWorkspace.shared.runningApplications.compactMap { app -> SwitchItem? in
            guard app.activationPolicy == .regular else { return nil }
            guard let bundleID = app.bundleIdentifier, bundleID != selfBundleID else { return nil }
            guard !excludedBundleIDs.contains(bundleID) else { return nil }

            let title = app.localizedName ?? bundleID
            return SwitchItem(
                id: "app:\(bundleID)",
                title: title,
                subtitle: "",
                icon: app.icon,
                kind: .app,
                activate: { app.activate(options: [.activateIgnoringOtherApps]) }
            )
        }
    }
}
