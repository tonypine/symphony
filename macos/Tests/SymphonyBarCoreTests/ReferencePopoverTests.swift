import Foundation
import XCTest
@testable import SymphonyBarCore

final class ReferencePopoverTests: XCTestCase {
    func testTheTicketPopoverForTP891() throws {
        let popover = try popover(for: "TP-891", in: try XCTUnwrap(decision().review.action?.question))
        guard case let .ticket(ticket) = popover.content else { return XCTFail("TP-891's popover isn't a ticket's") }
        XCTAssertEqual(ticket.identifier, "TP-891")
        XCTAssertEqual(ticket.repoKey, "symphony")
        XCTAssertEqual(ticket.badge, .init(status: .working, word: "Code Review"))
        XCTAssertEqual(ticket.title, "Remove the retired review states and the version switch from the code")
        XCTAssertEqual(ticket.summary, "Removes the review states nobody uses any more, and the switch between the old and new flows.")
        XCTAssertEqual(ticket.facts, [
            .init(label: "Part of", value: "TP-880 · Remove the Supervisor check"),
            .init(label: "Work", value: "PR #446 · checks running"),
        ])
        XCTAssertEqual(popover.hint, "Click to open the ticket page")
        XCTAssertEqual(popover.link, .init(title: "Open in Linear", url: try XCTUnwrap(URL(string: "https://linear.app/tonypine/issue/TP-891"))))
    }

    func testATicketWaitingOnTheDirectorSaysSo() throws {
        let popover = try popover(for: "TP-892", in: try XCTUnwrap(decision().review.action?.question))
        guard case let .ticket(ticket) = popover.content else { return XCTFail("TP-892's popover isn't a ticket's") }
        XCTAssertEqual(ticket.badge, .init(status: .you, word: "Rework"))
        XCTAssertEqual(ticket.facts.last, .init(label: "Waiting on", value: "you"))
    }

    func testThePullRequestPopoverFor448() throws {
        let popover = try popover(for: "#448", in: try XCTUnwrap(decision().review.action?.why))
        guard case let .pullRequest(pullRequest) = popover.content else { return XCTFail("#448's popover isn't a pull request's") }
        XCTAssertEqual(pullRequest.number, "#448")
        XCTAssertEqual(pullRequest.forTicket, "for TP-892")
        XCTAssertEqual(pullRequest.state, .init(status: .you, word: "Changes asked"))
        XCTAssertEqual(pullRequest.title, "Remove the Final verification and Supervisor check flows")
        XCTAssertEqual(pullRequest.summary, "The Final verification and Supervisor check steps are gone, so a ticket goes from QA straight to Merging.")
        XCTAssertEqual(pullRequest.stats.map(\.accessibilityLabel), ["2 review rounds", "14 files", "+120 −486 lines", "Checks passed"])
        XCTAssertEqual(pullRequest.stats.last?.status, .done)
        XCTAssertEqual(popover.hint, "Click to open it on GitHub")
        XCTAssertEqual(popover.link?.title, "Open on GitHub")
        XCTAssertEqual(popover.link?.url.absoluteString, "https://github.com/tonypine/symphony/pull/448")
    }

    func testAPullRequestWithOneOfEachAndNoFiguresYet() {
        let mention = Mentions.find(in: "PR #9", references: ["PR #9": .pullRequest(.init(number: 9, reviewState: .merged, reviewRounds: 1, files: 1, checks: .failed))])[0]
        guard case let .pullRequest(pullRequest) = ReferencePopover(mention).content else { return XCTFail("not a pull request") }
        XCTAssertEqual(pullRequest.stats.map(\.accessibilityLabel), ["1 review round", "1 file", "Checks failed"])
        XCTAssertEqual(pullRequest.state, .init(status: .done, word: "Merged"))
        XCTAssertNil(pullRequest.forTicket)
        XCTAssertNil(ReferencePopover(mention).link)
    }

    func testAMentionSymphonyCannotSee() {
        let unknown = Mentions.find(in: "TP-999", references: [:])[0]
        XCTAssertEqual(ReferencePopover(unknown).content, .missing("Symphony can't see TP-999."))
        XCTAssertNil(ReferencePopover(unknown).link)
        XCTAssertNil(ReferencePopover(unknown).hint)

        let url = URL(string: "https://github.com/acme/api/pull/7")!
        let unreadable = Mentions.find(in: "PR #7", references: ["PR #7": .missing(url: url)])[0]
        XCTAssertEqual(ReferencePopover(unreadable).content, .missing("Symphony can't see PR #7."))
        XCTAssertEqual(ReferencePopover(unreadable).link, .init(title: "Open on GitHub", url: url))
        let ticket = Mentions.find(in: "TP-7", references: ["TP-7": .missing(url: url)])[0]
        XCTAssertEqual(ReferencePopover(ticket).link?.title, "Open in Linear")
    }

    func testAStageTakesItsStatus() {
        XCTAssertEqual(ReferencePopover.status(state: "Done", waitingOn: nil), .done)
        XCTAssertEqual(ReferencePopover.status(state: "Backlog", waitingOn: nil), .idle)
        XCTAssertEqual(ReferencePopover.status(state: "Canceled", waitingOn: nil), .idle)
        XCTAssertEqual(ReferencePopover.status(state: "Plan Review", waitingOn: nil), .you)
        XCTAssertEqual(ReferencePopover.status(state: "In Progress", waitingOn: nil), .working)
        XCTAssertEqual(ReferencePopover.status(state: "Rework", waitingOn: "you"), .you)
        XCTAssertEqual([Reference.Checks.passed, .failed, .pending].map(\.status), [.done, .problem, .working])
        XCTAssertEqual(
            [.open, .changesRequested, .approved, .merged, .closed].map { (state: Reference.PullRequest.ReviewState) in state.status },
            [.working, .you, .done, .done, .idle]
        )
    }

    private func popover(for key: String, in text: String) throws -> ReferencePopover {
        let mention = try XCTUnwrap(Mentions.find(in: text, references: try decision().references).first { $0.key == key })
        return ReferencePopover(mention)
    }

    private func decision() throws -> InboxItem {
        try XCTUnwrap(MentionsTests().decisionItem())
    }
}
