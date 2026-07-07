import AppKit

enum SwitchItemKind {
    case app
    case browserTab
    case terminalTab
}

/// One searchable result in the overlay: either a plain running app (the
/// generic fallback for anything we have no specialised integration for -
/// Teams, Xcode, Finder, ...) or a deep result like a specific browser tab
/// or terminal session/tab.
struct SwitchItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let icon: NSImage?
    let kind: SwitchItemKind

    /// Brings this item to the foreground. Called on the main thread; may
    /// itself dispatch blocking work (e.g. AppleScript) to a background queue.
    let activate: () -> Void
}

extension SwitchItem {
    /// Combined fuzzy score against `query`, weighting the title higher than
    /// the subtitle (app name / URL). Tries an ordered subsequence match
    /// first; if `query` doesn't appear as a subsequence in either field at
    /// all (e.g. transposed or mistyped characters, not just missing ones),
    /// falls back to a typo-tolerant token comparison so a close-but-garbled
    /// query still surfaces instead of vanishing entirely. Returns nil only
    /// if neither approach finds anything.
    func matchScore(for query: String) -> Int? {
        guard !query.isEmpty else { return 0 }
        let titleMatch = FuzzyMatcher.match(pattern: query, in: title)
        let subtitleMatch = subtitle.isEmpty ? nil : FuzzyMatcher.match(pattern: query, in: subtitle)
        switch (titleMatch, subtitleMatch) {
        case let (t?, s?): return t * 2 + s
        case let (t?, nil): return t * 2
        case let (nil, s?): return s
        case (nil, nil):
            let titleTypo = FuzzyMatcher.typoScore(pattern: query, in: title) ?? 0
            let subtitleTypo = subtitle.isEmpty ? 0 : (FuzzyMatcher.typoScore(pattern: query, in: subtitle) ?? 0)
            let best = max(titleTypo, subtitleTypo)
            return best > 0 ? best : nil
        }
    }
}
