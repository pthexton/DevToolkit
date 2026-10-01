import AppKit

/// Prefix commands typed into the search field that bypass window search
/// entirely, e.g. `jira:AIDR-2100` opens that ticket in the browser.
enum QuickCommand {
    static let jiraPrefix = "jira:"
    static let jiraBrowseBase = "https://beyondtrust.atlassian.net/browse/"

    /// True when `query` starts with a recognised command prefix, in which
    /// case normal fuzzy results should be replaced by `item(for:)`.
    static func isCommand(_ query: String) -> Bool {
        query.lowercased().hasPrefix(jiraPrefix)
    }

    /// The Jira browse URL for a `jira:<ticket>` query, or nil if the query
    /// isn't a Jira command or has no ticket ID yet.
    static func jiraURL(for query: String) -> URL? {
        guard isCommand(query) else { return nil }
        let ticket = query.dropFirst(jiraPrefix.count).trimmingCharacters(in: .whitespaces)
        guard !ticket.isEmpty,
              let encoded = ticket.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        else { return nil }
        return URL(string: jiraBrowseBase + encoded)
    }

    /// The single result row to show for a command query, or nil if the
    /// command is incomplete.
    static func item(for query: String) -> SwitchItem? {
        guard let url = jiraURL(for: query) else { return nil }
        return SwitchItem(
            id: "command:\(url.absoluteString)",
            title: "Open \(url.lastPathComponent) in Jira",
            subtitle: url.absoluteString,
            icon: nil,
            kind: .command,
            activate: { NSWorkspace.shared.open(url) }
        )
    }
}
