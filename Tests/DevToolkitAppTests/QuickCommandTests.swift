import XCTest
@testable import DevToolkitApp

final class QuickCommandTests: XCTestCase {

    func testJiraPrefixBuildsBrowseURL() {
        XCTAssertEqual(
            QuickCommand.jiraURL(for: "jira:AIDR-2100")?.absoluteString,
            "https://beyondtrust.atlassian.net/browse/AIDR-2100"
        )
    }

    func testPrefixIsCaseInsensitiveAndTicketIsTrimmed() {
        XCTAssertEqual(
            QuickCommand.jiraURL(for: "JIRA:  EPM-12 ")?.absoluteString,
            "https://beyondtrust.atlassian.net/browse/EPM-12"
        )
    }

    func testEmptyTicketIsStillACommandButHasNoURL() {
        XCTAssertTrue(QuickCommand.isCommand("jira:"))
        XCTAssertNil(QuickCommand.jiraURL(for: "jira:"))
        XCTAssertNil(QuickCommand.jiraURL(for: "jira:   "))
    }

    func testNonCommandQueriesAreIgnored() {
        XCTAssertFalse(QuickCommand.isCommand("jir"))
        XCTAssertFalse(QuickCommand.isCommand("open jira:AIDR-1"))
        XCTAssertNil(QuickCommand.item(for: "safari"))
    }

    @MainActor
    func testViewModelReplacesResultsWithCommandItem() {
        let viewModel = SearchViewModel()
        viewModel.allItems = [
            SwitchItem(id: "a", title: "jira board", subtitle: "", icon: nil, kind: .browserTab, activate: {})
        ]
        viewModel.query = "jira:AIDR-2100"
        XCTAssertEqual(viewModel.results.map(\.kind), [.command])
        XCTAssertEqual(viewModel.results.first?.title, "Open AIDR-2100 in Jira")

        viewModel.query = "jira:"
        XCTAssertTrue(viewModel.results.isEmpty)
    }
}
