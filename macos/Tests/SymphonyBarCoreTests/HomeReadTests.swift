import Foundation
import XCTest
@testable import SymphonyBarCore

/// Home's two lists (TP-1499) from `GET /api/v1/home`: what is in progress under its epics, and the queue as a tree, each
/// row one line with its glyph, its trail and its move.
final class HomeReadTests: XCTestCase {
    /// The `home` fixture's clock: its Home read holds the catalog's `PROGRESS` and `QUEUE`.
    private let reference = ISO8601DateFormatter().date(from: "2026-10-07T14:20:00Z")!

    // MARK: - In progress

    /// Walkthrough step 1: "In progress" lists what has started, tickets of an epic under the epic with its strip.
    func testInProgressPutsAnEpicsTicketsUnderItsRowAndTheRestAtTheTopLevel() throws {
        let lists = try lists()

        XCTAssertEqual(lists.progress.map(\.id), ["SHOP-280", "BIL-300", "TP-1492", "TP-1480", "TP-1376"])
        XCTAssertEqual(lists.progress[0].children.map(\.id), ["SHOP-305", "SHOP-301"])
        XCTAssertEqual(lists.progress[1].children.map(\.id), ["BIL-306", "BIL-307"])
        XCTAssertTrue(lists.progress[2...].allSatisfy(\.children.isEmpty))

        let epic = try XCTUnwrap(lists.row("SHOP-280"))
        XCTAssertTrue(epic.isEpic)
        XCTAssertEqual(epic.lead, .epic)
        XCTAssertEqual(epic.title, "Checkout that survives a reload")
        XCTAssertEqual(epic.value, "4 of 9")
        XCTAssertEqual(epic.issueID, "epic-shop-280")
        XCTAssertEqual(epic.strip?.map(\.status), [.done, .done, .done, .done, .working, .working, nil, nil, nil])
        XCTAssertEqual(epic.strip?.filter(\.live).count, 2, "the tickets in progress breathe")
        XCTAssertNil(epic.badge)
        XCTAssertNil(epic.move)

        let plans = try XCTUnwrap(lists.row("BIL-300"))
        XCTAssertEqual(plans.value, "1 of 4")
        XCTAssertEqual(plans.strip?.map(\.status), [.done, .you, .working, nil])
    }

    /// A row is one line: the live dot while a run works, the situation's glyph otherwise, the situation as a badge
    /// and how long it has held, on Symphony's clock.
    func testATicketRowCarriesItsGlyphBadgeAndAge() throws {
        let lists = try lists()

        let coding = try XCTUnwrap(lists.row("SHOP-305"))
        XCTAssertEqual(coding.lead, .live)
        XCTAssertEqual(coding.badge, HomeLists.Row.Badge(status: .working, word: "Coding"))
        XCTAssertEqual(coding.value, "14 min")
        XCTAssertNil(coding.after)
        XCTAssertNil(coding.epic, "the epic is a chip in the queue only")

        let ci = try XCTUnwrap(lists.row("SHOP-301"))
        XCTAssertEqual(ci.lead, .status(.working))
        XCTAssertEqual(ci.badge?.word, "Waiting for CI")
        XCTAssertEqual(ci.value, "6 min")

        XCTAssertEqual(lists.row("BIL-306")?.value, "3 h 12 min")
        XCTAssertEqual(lists.row("TP-1376")?.badge, HomeLists.Row.Badge(status: .problem, word: "Retrying at 16:02"))
    }

    /// Walkthrough step 4: a ticket waiting on the Director's answer carries Answer; one stopped by them Unblock; no
    /// other row has a button.
    func testOnlyATicketThatNeedsTheDirectorCarriesItsMove() throws {
        let lists = try lists()

        XCTAssertEqual(lists.row("BIL-306")?.move, HomeLists.Row.Move(name: "answer", title: "Answer", reason: nil))
        XCTAssertEqual(lists.row("BIL-306")?.lead, .status(.you))
        XCTAssertEqual(lists.row("TP-1480")?.move, HomeLists.Row.Move(name: "unblock", title: "Unblock", reason: nil))
        let moving = lists.rows.values.filter { $0.move != nil }.map(\.identifier).sorted()
        XCTAssertEqual(moving, ["BIL-306", "TP-1480"])
    }

    func testAMoveTheReadRefusesKeepsItsReason() {
        XCTAssertEqual(
            HomeLists.move(HomeRead.Move(name: "unblock", allowed: false, reason: "A run is starting")),
            HomeLists.Row.Move(name: "unblock", title: "Unblock", reason: "A run is starting")
        )
        XCTAssertEqual(HomeLists.move(HomeRead.Move(name: "unblock", allowed: false)).reason, TicketActionRail.unknownReason)
        XCTAssertEqual(HomeLists.move(HomeRead.Move(name: "retry")).title, "Retry")
    }

    // MARK: - Queue

    /// Walkthrough step 2: the queue as a tree; a chain of nine shows three rows and "+6".
    func testTheQueueIsATreeAndALongChainFoldsPastTwoSteps() throws {
        let lists = try lists()

        XCTAssertEqual(lists.queue.map(\.id), ["TP-1481", "SHOP-311", "BIL-308", "MOT-93"])
        XCTAssertEqual(lists.queue[0].descendants, 8)
        XCTAssertEqual(lists.queue[1].children.map(\.id), ["SHOP-312", "SHOP-313"])
        XCTAssertEqual(lists.queue[1].children[0].children.map(\.id), ["SHOP-314"])

        let folded = TreeLines.lines(lists.queue, foldDepth: DesignTokens.Tree.foldDepth)
        let chain = folded.prefix { $0.root == "TP-1481" }
        XCTAssertEqual(chain.map(\.key), [.row("TP-1481"), .row("TP-1482"), .row("TP-1483"), .more("TP-1483")])
        XCTAssertEqual(chain.last?.hidden, 6)
        XCTAssertEqual(DesignTokens.Tree.More.text(6), "+6")

        let open = TreeLines.lines(lists.queue, foldDepth: DesignTokens.Tree.foldDepth, opened: ["TP-1481"])
        XCTAssertEqual(open.filter { $0.root == "TP-1481" }.count, 9, "a click shows the whole branch")
    }

    /// A root that waits on a ticket in progress names it at the right; a queued ticket shows its epic; a root that
    /// waits on nothing carries its situation; every other queued row starts with the clock and has no badge or age.
    func testAQueueRowCarriesWhatItComesAfterItsEpicAndItsSituation() throws {
        let lists = try lists()

        let root = try XCTUnwrap(lists.row("SHOP-311"))
        XCTAssertEqual(root.after, "SHOP-305")
        XCTAssertEqual(root.epic, "Checkout")
        XCTAssertEqual(root.lead, .waiting)
        XCTAssertNil(root.badge)
        XCTAssertNil(root.value)
        XCTAssertEqual(HomeLists.Row.afterHelp("SHOP-305"), "Starts when SHOP-305 lands")

        XCTAssertEqual(lists.row("SHOP-312")?.epic, "Checkout")
        XCTAssertNil(lists.row("SHOP-312")?.after)
        XCTAssertEqual(lists.row("TP-1481")?.after, "TP-1480")
        XCTAssertNil(lists.row("TP-1481")?.epic)

        let ready = try XCTUnwrap(lists.row("MOT-93"))
        XCTAssertEqual(ready.badge, HomeLists.Row.Badge(status: .idle, word: "Waiting for a slot"))
        XCTAssertEqual(ready.lead, .status(.idle))
        XCTAssertNil(ready.value, "no since, no age")
        XCTAssertNil(ready.move)
    }

    // MARK: - Empty and unreadable

    /// Walkthrough step 3: nothing says "None right now": a list with no entries is not drawn.
    func testAnEmptyReadHasNoList() throws {
        let read = try XCTUnwrap(HomeRead.decode(Data(#"{"in_progress": [], "queue": {"roots": []}, "outside": {}}"#.utf8)))
        let lists = HomeLists(read: read, reference: reference)
        XCTAssertTrue(lists.isEmpty)
        XCTAssertTrue(lists.rows.isEmpty)
        XCTAssertFalse(try self.lists().isEmpty)

        let bare = try XCTUnwrap(HomeRead.decode(Data("{}".utf8)))
        XCTAssertEqual(bare, HomeRead())
    }

    func testAnAnswerThatIsNotTheReadDecodesToNothing() {
        XCTAssertNil(HomeRead.decode(Data("[]".utf8)))
        XCTAssertNil(HomeRead.decode(Data("not json".utf8)))
    }

    /// An entry's missing fields: a ticket with no title reads its identifier, an epic with no total sums its counts,
    /// a ticket's age falls back on its situation's.
    func testMissingFieldsReadAsTheirDefaults() throws {
        let json = #"""
        {"in_progress": [
          {"kind": "epic", "identifier": "E-1", "counts": {"done": 2, "needs_fix": 1}, "tickets": [
            {"kind": "ticket", "identifier": "T-1", "situation": {"kind": "waiting_for_build", "since": "2026-10-07T14:00:00Z"}}
          ]},
          {"identifier": "T-2"}
        ], "queue": {"roots": [{"identifier": "Q-1", "epic": {"identifier": "E-9"}}]}}
        """#
        let read = try XCTUnwrap(HomeRead.decode(Data(json.utf8)))
        guard case let .epic(epic) = read.inProgress[0] else { return XCTFail("an epic") }
        XCTAssertNil(epic.issueID)
        XCTAssertEqual(epic.total, 3)
        XCTAssertEqual(epic.counts, HomeRead.Counts(done: 2, needsFix: 1))
        XCTAssertEqual(read.inProgress[1], .ticket(HomeRead.Ticket(identifier: "T-2")))

        let lists = HomeLists(read: read, reference: reference)
        XCTAssertEqual(lists.row("E-1")?.title, "E-1")
        XCTAssertEqual(lists.row("E-1")?.strip?.map(\.status), [.done, .done, .problem])
        XCTAssertEqual(lists.row("T-1")?.value, "20 min")
        XCTAssertEqual(lists.row("T-1")?.lead, .status(.working))
        XCTAssertEqual(lists.row("T-2")?.lead, .waiting)
        XCTAssertNil(lists.row("T-2")?.value)
        XCTAssertEqual(lists.row("Q-1")?.epic, "E-9", "an epic with no title shows its identifier")
    }

    /// The read with the slot entries and the queue rows the new Home reads (TP-1631): the present lists decode as
    /// before, and the new keys change nothing in them.
    func testTheReadWithSlotEntriesAndQueueRowsStillDecodesItsLists() throws {
        let json = #"""
        {"in_progress": [{"kind": "ticket", "identifier": "T-1", "title": "Working", "phase": "In Progress",
                          "situation": {"kind": "working", "since": "2026-10-07T14:00:00Z"}, "working": true, "in_progress": true}],
         "queue": {"roots": [{"identifier": "Q-1", "title": "Next", "children": [{"identifier": "Q-2", "children": []}]}],
                   "rows": [{"issue_id": "q1", "identifier": "Q-1", "number": "1", "path": [1], "parent": null, "phase": "Todo",
                             "waits_on": [{"identifier": "T-1", "kind": "released"}], "sub_tickets": {"done": 1, "total": 3}}],
                   "count": 1, "total": 1, "offset": 0, "limit": 100, "next_offset": null, "view": null, "filters": []},
         "outside": {"backlog": 0, "below_priority": 0, "epic": 0, "behind": 0},
         "slots": {"total": 2, "used": 1, "free": 1, "holders": [],
                   "entries": [{"slot": 1, "empty": false, "since": "2026-10-07T13:00:00Z",
                                "epic": {"identifier": "E-1", "done": 2, "total": 5},
                                "ticket": {"identifier": "T-1", "stages": [{"id": "coding", "state": "current", "tokens": 12}],
                                           "tokens": {"used": 12, "budget": null}, "plan": null, "checks": null, "pull_request": null}},
                               {"slot": 2, "empty": true, "since": null, "epic": null, "ticket": null}]}}
        """#
        let read = try XCTUnwrap(HomeRead.decode(Data(json.utf8)))
        XCTAssertEqual(read.inProgress.count, 1)
        XCTAssertEqual(read.queue.count, 1)

        let lists = HomeLists(read: read, reference: reference)
        XCTAssertEqual(lists.progress.map(\.id), ["T-1"])
        XCTAssertEqual(lists.queue.map(\.id), ["Q-1"])
        XCTAssertEqual(lists.queue[0].children.map(\.id), ["Q-2"])
        XCTAssertEqual(lists.row("T-1")?.lead, .live)
    }

    // MARK: - Two lists walked as one

    /// The arrow keys walk the rows of both lists in order: past a list's last line or first line is the other list.
    func testTheEdgesOfAListHandTheArrowsToTheNextList() throws {
        let lists = try lists()
        let progress = TreeLines.lines(lists.progress)
        let queue = TreeLines.lines(lists.queue, foldDepth: DesignTokens.Tree.foldDepth)

        XCTAssertTrue(TreeLines.isEdge(.row("TP-1376"), going: 1, in: progress))
        XCTAssertFalse(TreeLines.isEdge(.row("TP-1376"), going: -1, in: progress))
        XCTAssertTrue(TreeLines.isEdge(.row("SHOP-280"), going: -1, in: progress))
        XCTAssertFalse(TreeLines.isEdge(.row("BIL-306"), going: 1, in: progress))
        XCTAssertFalse(TreeLines.isEdge(.row("NOPE-1"), going: 1, in: progress))

        XCTAssertEqual(TreeLines.end(queue, last: false), .row("TP-1481"))
        XCTAssertEqual(TreeLines.end(progress, last: true), .row("TP-1376"))
        XCTAssertNil(TreeLines.end([TreeLine<String>](), last: true))
    }

    /// The QA fixture's Inbox holds the question of every row that offers Answer, so Answer opens it in the drawer
    /// instead of leaving the drawer reading.
    func testTheFixturesInboxHoldsTheQuestionOfEveryAnswerRow() throws {
        let answering = try lists().rows.values.filter { $0.move?.name == "answer" }.map(\.identifier).sorted()
        XCTAssertEqual(answering, ["BIL-306"])
        let inbox = try XCTUnwrap(InboxPayload.decode(Data(contentsOf: fixture("inbox.json"))))
        for identifier in answering {
            let item = try XCTUnwrap(inbox.items.first { $0.identifier == identifier }, identifier)
            XCTAssertTrue(item.isDecision, identifier)
        }
    }

    // MARK: - A provider that refuses the agents' sign-in (TP-1515)

    /// Home says once, for the whole factory, that agents can't sign in, with the provider's message and since when,
    /// from the committed sign-in fixture; the ticket that is due a QA run reads the same wait.
    func testASignInHoldIsOneLineAboveTheLists() throws {
        let utc = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let state = try XCTUnwrap(OverviewState.decode(try Data(contentsOf: fixture("state.json", in: "sign-in-hold"))))
        let notices = HomeLists.notices(state.snapshot, reference: reference, timeZone: utc)
        XCTAssertEqual(notices, [
            "Agents can't sign in to Claude since 14:02 (Failed to authenticate. API Error: 403 Attention Required! | "
                + "Cloudflare): new runs wait until 14:24.",
        ])

        let read = try XCTUnwrap(HomeRead.decode(try Data(contentsOf: fixture("home.json", in: "sign-in-hold"))))
        let lists = HomeLists(read: read, reference: reference, notices: notices)
        XCTAssertEqual(lists.notices, notices)
        XCTAssertEqual(lists.row("SHOP-301")?.badge?.word, "Waiting: the agent can't sign in to Claude")

        XCTAssertTrue(try self.lists().notices.isEmpty, "Home's own fixture holds nothing")
        let plain = try XCTUnwrap(OverviewState.decode(try Data(contentsOf: fixture("state.json"))))
        XCTAssertTrue(HomeLists.notices(plain.snapshot, reference: reference, timeZone: utc).isEmpty)
    }

    /// The line is gone once the probe checks the sign-in (canary), and a usage limit or an unreachable API has none.
    func testOnlyAHeldSignInHasALine() {
        func limit(_ reason: String, phase: StateSnapshot.UsageLimit.Phase = .paused) -> StateSnapshot.UsageLimit {
            StateSnapshot.UsageLimit(phase: phase, reason: reason)
        }
        var snapshot = StateSnapshot()
        snapshot.usageLimits = [limit("model_api_sign_in_failed", phase: .canary), limit("usage_limit"), limit("model_api_unreachable")]
        XCTAssertTrue(HomeLists.notices(snapshot, reference: reference).isEmpty)

        snapshot.usageLimits = [limit("model_api_sign_in_failed")]
        XCTAssertEqual(HomeLists.notices(snapshot, reference: reference), ["Agents can't sign in to Claude: new runs wait."])
    }

    private func lists() throws -> HomeLists {
        let read = try XCTUnwrap(HomeRead.decode(try Data(contentsOf: fixture("home.json"))))
        return HomeLists(read: read, reference: reference)
    }

    private func fixture(_ name: String, in directory: String = "home") -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/director-app/\(directory)/api/v1/\(name)")
    }

    // MARK: - No read to show

    /// A read that gives Home nothing to show says why: an older Symphony asks for an update, a failure names itself,
    /// and a body that doesn't decode says so, never the "Reading Home…" spinner for good.
    func testAReadWithNothingToShowSaysWhy() {
        XCTAssertEqual(HomeLists.failure(after: .changed(.unsupported, etag: nil)), .unsupported)
        XCTAssertEqual(
            HomeLists.failure(after: .changed(.failed("Symphony isn't answering"), etag: nil)),
            .failed("Symphony isn't answering")
        )
        XCTAssertEqual(HomeLists.failure(after: .changed(.loaded(Data("not json".utf8)), etag: "v1")), .failed(HomeLists.unreadable))
        XCTAssertEqual(HomeLists.failure(after: .unchanged), .failed(HomeLists.unreadable))
    }
}
