import Foundation
import XCTest
@testable import SymphonyBarCore

final class ContextCardTests: XCTestCase {
    /// The `inbox-decision` fixture's `generated_at`, in UTC.
    private let now = ISO8601DateFormatter().date(from: "2026-10-07T14:20:00Z")!
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    func testTheDecisionFixtureSaysWhereTP892Sits() throws {
        let item = try XCTUnwrap(try payload("inbox-decision").items.first { $0.identifier == "TP-892" })
        let card = try XCTUnwrap(ContextCard(item: item, now: now, calendar: utc))

        XCTAssertEqual(ContextCard.title, "Where this ticket sits")
        XCTAssertEqual(card.partOf?.text, "TP-870 · Simplify the review flow")
        let strip = try XCTUnwrap(card.partOf?.progress)
        XCTAssertEqual(strip.segments, [.done, .done, .done, .done, .working, .notStarted, .notStarted])
        XCTAssertEqual(strip.line, "4 of 7 done")
        XCTAssertEqual(strip.accessibilityLabel, "4 of 7 sub-tickets done")

        XCTAssertEqual(card.work, "#448 · checks passing · sent back twice")
        XCTAssertEqual(card.connected, [
            .init(identifier: "TP-893", stage: .init(status: .idle, word: "Todo"), relation: "waits on TP-892"),
            .init(identifier: "TP-891", stage: .init(status: .working, word: "Code Review"), relation: "related"),
        ])
        XCTAssertEqual(card.answer, "Unblocks TP-893, the app's view of the new review steps.")
        XCTAssertEqual(card.earlierCalls, [
            .init(time: "05:48", text: "Keep the Supervisor check's log for a week · You chose “Remove it with the rest, in TP-880”"),
        ])

        // The item's own references win; the parent, which the text never mentions, gets one from the context.
        XCTAssertEqual(card.references["TP-891"], item.references["TP-891"])
        XCTAssertEqual(card.references["#448"], item.references["#448"])
        XCTAssertEqual(card.references["TP-870"], .ticket(Reference.Ticket(identifier: "TP-870", title: "Simplify the review flow")))
    }

    func testAnItemWithNothingKnownHasNoCard() throws {
        let plan = try XCTUnwrap(try payload("inbox-decision").items.first { $0.identifier == "TP-923" })
        XCTAssertNil(ContextCard(item: plan, now: now, calendar: utc))
        XCTAssertNil(ContextCard(item: InboxItem(id: "i", identifier: "X-1", kind: .pr, ask: "Merge?")))
        // A blank unblocks and an earlier decision with nothing to say are no rows either.
        let blank = item(unblocks: "  ", context: TicketContext(earlierDecisions: [.init(at: now, title: nil, answer: nil)]))
        XCTAssertNil(ContextCard(item: blank, now: now, calendar: utc))
    }

    func testOnlyUnblocksShowsOnlyYourAnswer() throws {
        let card = try XCTUnwrap(ContextCard(item: item(unblocks: "the Release workflow on main"), now: now, calendar: utc))
        XCTAssertEqual(card.answer, "Unblocks the Release workflow on main.")
        XCTAssertNil(card.partOf)
        XCTAssertNil(card.work)
        XCTAssertTrue(card.connected.isEmpty)
        XCTAssertTrue(card.earlierCalls.isEmpty)
        XCTAssertEqual(ContextCard.sentence("unblocks the release!"), "Unblocks the release!")
        XCTAssertEqual(ContextCard.sentence("Unblocks the release"), "Unblocks the release.")
    }

    func testEachConnectionSaysHowItRelatesInWords() throws {
        let context = TicketContext(
            blockedBy: [.init(identifier: "TP-1", title: "First", state: "Done")],
            blocks: [.init(identifier: "TP-2", title: nil, state: nil)],
            related: [.init(identifier: "TP-3", title: "Third", state: "Plan Review")]
        )
        let card = try XCTUnwrap(ContextCard(item: item(context: context), now: now, calendar: utc))
        XCTAssertEqual(card.connected, [
            .init(identifier: "TP-1", stage: .init(status: .done, word: "Done"), relation: "X-9 waits on it"),
            .init(identifier: "TP-2", stage: nil, relation: "waits on X-9"),
            .init(identifier: "TP-3", stage: .init(status: .you, word: "Plan Review"), relation: "related"),
        ])
        XCTAssertEqual(card.references["TP-1"], .ticket(Reference.Ticket(identifier: "TP-1", title: "First", state: "Done")))
        XCTAssertNil(card.partOf)
        XCTAssertNil(card.work)
    }

    func testItsWorkSaysTheChecksAndHowOftenCodeReviewSentItBack() throws {
        func work(_ checks: Reference.Checks?, _ sentBack: Int, references: [String: Reference] = [:]) -> String? {
            let url = URL(string: "https://github.com/acme/api/pull/7")
            let context = TicketContext(pullRequest: .init(number: 7, url: url, checks: checks, sentBack: sentBack))
            return ContextCard(item: item(context: context, references: references), now: now, calendar: utc)?.work
        }
        XCTAssertEqual(work(.failed, 1), "#7 · checks failing · sent back once")
        XCTAssertEqual(work(.pending, 3), "#7 · checks running · sent back 3 times")
        XCTAssertEqual(work(nil, 0), "#7")
        // The text names the pull request as the item's references do, so its chip finds it.
        XCTAssertEqual(work(nil, 0, references: ["PR #7": .missing(url: nil)]), "PR #7")

        let context = TicketContext(pullRequest: .init(number: 7, url: URL(string: "https://github.com/acme/api/pull/7"), checks: nil, sentBack: 0))
        let card = try XCTUnwrap(ContextCard(item: item(context: context), now: now, calendar: utc))
        XCTAssertEqual(card.references["#7"], .missing(url: URL(string: "https://github.com/acme/api/pull/7")))
    }

    func testAnEarlierCallShowsItsTimeTodayAndItsDateBefore() throws {
        let at = { ISO8601DateFormatter().date(from: $0)! }
        XCTAssertEqual(ContextCard.time(at("2026-10-07T05:48:00Z"), now: now, calendar: utc), "05:48")
        XCTAssertEqual(ContextCard.time(at("2026-10-06T23:10:00Z"), now: now, calendar: utc), "Oct 6, 23:10")
        XCTAssertEqual(ContextCard.time(at("2025-12-31T09:05:00Z"), now: now, calendar: utc), "Dec 31, 2025, 09:05")

        let context = TicketContext(earlierDecisions: [
            .init(at: nil, title: "Ship it?", answer: nil),
            .init(at: at("2026-10-07T09:00:00Z"), title: nil, answer: "Wait a day"),
        ])
        let card = try XCTUnwrap(ContextCard(item: item(context: context), now: now, calendar: utc))
        XCTAssertEqual(card.earlierCalls, [
            .init(time: nil, text: "Ship it?"),
            .init(time: "09:00", text: "You chose “Wait a day”"),
        ])
    }

    func testTheStripColorsEachSubTicketByItsState() throws {
        let parent = TicketContext.Parent(identifier: "P-1", title: nil, done: 1, total: 4, children: ["completed", "started", "triage", "backlog"])
        let card = try XCTUnwrap(ContextCard(item: item(context: TicketContext(parent: parent)), now: now, calendar: utc))
        XCTAssertEqual(card.partOf?.text, "P-1")
        let strip = try XCTUnwrap(card.partOf?.progress)
        XCTAssertEqual(strip.segments, [.done, .working, .waitingOnYou, .notStarted])
        XCTAssertEqual(strip.segments.map(\.color), [.green, .blue, .orange, .separator])
        XCTAssertEqual(ProgressStrip(TicketContext.Parent(identifier: "P", title: nil, done: 1, total: 1, children: ["completed"]))?.accessibilityLabel, "1 of 1 sub-ticket done")

        // A parent without sub-tickets has no strip.
        let lone = TicketContext(parent: .init(identifier: "P-2", title: "Alone", done: 0, total: 0, children: []))
        let alone = try XCTUnwrap(ContextCard(item: item(context: lone), now: now, calendar: utc))
        XCTAssertNil(alone.partOf?.progress)
    }

    private func item(unblocks: String? = nil, context: TicketContext? = nil, references: [String: Reference] = [:]) -> InboxItem {
        let action = unblocks.map { InboxReview.Action(title: nil, question: nil, why: nil, unblocks: $0, steps: [], options: []) }
        return InboxItem(id: "i-9", identifier: "X-9", kind: .action, ask: "Decide", review: InboxReview(action: action), references: references, context: context)
    }

    private func payload(_ name: String) throws -> InboxPayload {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/director-app/\(name)/api/v1/inbox.json")
        return try XCTUnwrap(InboxPayload.decode(Data(contentsOf: url)))
    }
}
