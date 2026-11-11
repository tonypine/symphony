import XCTest
@testable import SymphonyBarCore

final class HomeInboxTests: XCTestCase {
    func testListsEveryItemNewestFirstWithUnknownWaitsLast() throws {
        let items = [
            InboxItem(id: "a", identifier: "A-1", kind: .plan, ask: "Plan", waitingSeconds: 8100),
            InboxItem(id: "b", identifier: "B-1", kind: .action, ask: "Ask", waitingSeconds: 60),
            InboxItem(id: "c", identifier: "C-1", kind: .blocked, ask: "Blocked"),
            InboxItem(id: "d", identifier: "D-1", kind: .waiting, ask: "Waits on CI", waitingSeconds: 600),
            InboxItem(id: "e", identifier: "E-1", kind: .clarify, ask: "Clarify"),
        ]
        let home = HomeInbox(items: items)
        XCTAssertEqual(home.rows.map(\.id), ["b", "d", "a", "c", "e"])
        XCTAssertFalse(home.isEmpty)
        XCTAssertNil(home.hiddenLine)
        XCTAssertEqual(home.accessibilityLabel, "Needs you, 5")
        XCTAssertTrue(HomeInbox(items: []).isEmpty)
    }

    func testAnAnsweredItemLeavesAtOnceAndTheScopeHidesOtherRepos() throws {
        let items = try payload("inbox-decision").items
        let answered = try XCTUnwrap(items.first { $0.identifier == "TP-892" })
        let home = HomeInbox(items: items, answered: [answered.id])
        XCTAssertFalse(home.rows.contains { $0.item.identifier == "TP-892" })
        XCTAssertEqual(home.rows.count, items.count - 1)

        let mixed = [
            InboxItem(id: "a", identifier: "A-1", repoKey: "web-shop", kind: .action, ask: "Ask"),
            InboxItem(id: "b", identifier: "B-1", repoKey: "docs", kind: .action, ask: "Ask"),
        ]
        let scoped = HomeInbox(items: mixed, scope: .repo("docs"))
        XCTAssertEqual(scoped.rows.map(\.id), ["b"])
        XCTAssertEqual(scoped.hiddenLine, "1 more in another repo")
    }

    func testADecisionIsAnsweredInPlaceWithTheInboxsSendDecision() throws {
        let items = try payload("inbox-decision").items
        let row = try XCTUnwrap(HomeInbox(items: items).rows.first { $0.item.identifier == "TP-892" })
        XCTAssertTrue(row.asksInPlace)
        XCTAssertEqual(row.toolbar.defaultCommand, .move(.decide))
        XCTAssertEqual(row.commands.first, .inbox(.move(.decide)))
        XCTAssertEqual(row.commands.last, .review)
        XCTAssertEqual(HomeInbox.Command.review.title, "Review")
        XCTAssertEqual(HomeInbox.Command.inbox(.move(.decide)).title, "Send Decision…")

        // The write-in picked and left blank has nothing to send, as in the Inbox.
        let action = try XCTUnwrap(row.item.review.action)
        let blank = DecisionPicks(picks: [0: action.writeInIndex])
        let picked = HomeInbox(items: items, picks: { $0 == row.id ? blank : DecisionPicks() })
        XCTAssertEqual(picked.rows.first { $0.id == row.id }?.toolbar.buttons.first?.enabled, false)

        XCTAssertFalse(try XCTUnwrap(HomeInbox(items: items).rows.first { $0.item.kind == .plan }).asksInPlace)
    }

    /// Nothing a person could do from the Inbox is lost: each kind of item, in each of its shapes, offers on Home every
    /// command the Inbox's review offers, and Review opens the rest in the drawer.
    func testEveryInboxMoveOfEachKindIsReachableFromHome() throws {
        let fixtures = ["inbox", "inbox-decision", "inbox-waiting-ci", "inbox-unasked-choices"]
        var items = try fixtures.flatMap { try payload($0).items }
        items += try pausedItems()
        XCTAssertEqual(Set(items.map(\.kind)), Set(InboxItem.Kind.allCases), "a fixture is missing a kind of item")

        var reached = Set<InboxMove>()
        for item in items {
            let toolbar = InboxToolbar.toolbar(for: item)
            let row = try XCTUnwrap(HomeInbox(items: [item]).rows.first)
            let offered = toolbar.buttons.map { HomeInbox.Command.inbox($0.command) } + toolbar.overflow.map(HomeInbox.Command.inbox)
            for command in offered {
                XCTAssertTrue(row.commands.contains(command), "\(item.identifier) (\(item.kind)) loses \(command.title) on Home")
            }
            XCTAssertTrue(row.commands.contains(.review), "\(item.identifier) can't open its review")
            for case let .inbox(.move(move)) in row.commands { reached.insert(move) }
        }
        XCTAssertEqual(reached, Set(InboxMove.allCases), "a move of the Inbox is offered by no item on Home")
    }

    private func pausedItems() throws -> [InboxItem] {
        let directory = fixture("inbox-paused")
        let inbox = try XCTUnwrap(InboxPayload.decode(Data(contentsOf: directory.appendingPathComponent("inbox.json"))))
        return inbox.withPauses(fromState: try Data(contentsOf: directory.appendingPathComponent("state.json"))).items
    }

    private func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/director-app/\(name)/api/v1", isDirectory: true)
    }

    private func payload(_ name: String) throws -> InboxPayload {
        try XCTUnwrap(InboxPayload.decode(Data(contentsOf: fixture(name).appendingPathComponent("inbox.json"))))
    }
}
