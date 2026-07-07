import Foundation

@MainActor
final class SearchViewModel: ObservableObject {
    @Published var query: String = "" {
        didSet { selectedIndex = 0 }
    }
    @Published var allItems: [SwitchItem] = [] {
        didSet { selectedIndex = 0 }
    }
    @Published private(set) var mode: SearchMode = .all {
        didSet { selectedIndex = 0 }
    }
    @Published private(set) var selectedIndex: Int = 0
    /// Bumped each time the overlay is shown; SearchView observes this to
    /// re-focus the text field (a plain `onAppear` only fires once, since the
    /// panel is reused rather than recreated on every show/hide).
    @Published private(set) var focusToken: Int = 0

    var onSelect: ((SwitchItem) -> Void)?
    var onCancel: (() -> Void)?

    private let maxResults = 50

    private var modeFilteredItems: [SwitchItem] {
        allItems.filter { mode.matches($0.kind) }
    }

    var results: [SwitchItem] {
        let candidates = modeFilteredItems
        guard !query.isEmpty else {
            return Array(candidates.prefix(maxResults))
        }
        let scored: [(item: SwitchItem, score: Int)] = candidates.compactMap { item in
            guard let score = item.matchScore(for: query) else { return nil }
            return (item, score)
        }
        return scored
            .sorted { $0.score > $1.score }
            .prefix(maxResults)
            .map { $0.item }
    }

    func reset() {
        query = ""
        mode = .all
    }

    func setMode(_ newMode: SearchMode) {
        mode = newMode
    }

    func requestFocus() {
        DispatchQueue.main.async { self.focusToken += 1 }
    }

    func moveSelection(by delta: Int) {
        let count = results.count
        guard count > 0 else { return }
        selectedIndex = ((selectedIndex + delta) % count + count) % count
    }

    func selectCurrent() {
        let items = results
        guard items.indices.contains(selectedIndex) else { return }
        onSelect?(items[selectedIndex])
    }

    /// Used when the user clicks a row directly rather than navigating with
    /// arrow keys.
    func activate(at index: Int) {
        guard results.indices.contains(index) else { return }
        selectedIndex = index
        selectCurrent()
    }
}
