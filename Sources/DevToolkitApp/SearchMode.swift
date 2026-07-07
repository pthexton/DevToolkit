/// Which subset of `allItems` the overlay is currently searching.
/// Cycled via Cmd+0 (all) through Cmd+3 (terminal tabs).
enum SearchMode: CaseIterable, Hashable {
    case all
    case apps
    case browserTabs
    case terminalTabs

    var label: String {
        switch self {
        case .all: return "All"
        case .apps: return "Apps"
        case .browserTabs: return "Browser Tabs"
        case .terminalTabs: return "Terminal Tabs"
        }
    }

    var shortcutHint: String {
        switch self {
        case .all: return "\u{2318}0"
        case .apps: return "\u{2318}1"
        case .browserTabs: return "\u{2318}2"
        case .terminalTabs: return "\u{2318}3"
        }
    }

    func matches(_ kind: SwitchItemKind) -> Bool {
        switch self {
        case .all: return true
        case .apps: return kind == .app
        case .browserTabs: return kind == .browserTab
        case .terminalTabs: return kind == .terminalTab
        }
    }
}
