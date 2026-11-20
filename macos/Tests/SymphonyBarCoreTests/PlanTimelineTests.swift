import Foundation
@testable import SymphonyBarCore
import XCTest

/// A groomed ticket's timeline, from `Tests/Fixtures/timeline/plan.json`: the plan's events are one line each, a
/// person's message holds the Conductor's reply under it, and a message with no reply yet waits on top.
final class PlanTimelineTests: XCTestCase {
    private static let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/timeline/plan.json")

    private let reference = ISO8601DateFormatter().date(from: "2026-10-08T10:27:00Z")!

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func history() throws -> TicketEventsPayload {
        try XCTUnwrap(TicketEventsPayload.decode(Data(contentsOf: Self.fixture)))
    }

    private func entries(_ history: TicketEventsPayload) -> [TimelineEntry] {
        TimelineModel.build(history, reference: reference, calendar: utc).items.compactMap { item in
            if case let .entry(entry) = item { return entry }
            return nil
        }
    }

    private func entry(_ id: String) throws -> TimelineEntry {
        try XCTUnwrap(entries(try history()).first { $0.id == id })
    }

    private func page(_ events: [String]) throws -> TicketEventsPayload {
        try XCTUnwrap(TicketEventsPayload.decode(Data(#"{"timeline": [\#(events.joined(separator: ","))]}"#.utf8)))
    }

    // MARK: - The plan's events

    func testAPlanWrittenIsOneLineAndALaterVersionSaysWhyItChanged() throws {
        let written = try entry("g2")
        XCTAssertEqual(written.kind, .plan)
        XCTAssertEqual(written.title, "Plan written")
        XCTAssertNil(written.detail)
        XCTAssertFalse(written.isMechanical)

        let changed = try entry("r1")
        XCTAssertEqual(changed.title, "Plan changed: The button keeps the word Release")
        XCTAssertEqual(changed.lead, "Plan changed:")
        XCTAssertNil(changed.detail)
    }

    func testThePlanTitleReadsTheVersionAndTheReason() {
        XCTAssertEqual(TimelineEntry.planTitle(.init()), "Plan written")
        XCTAssertEqual(TimelineEntry.planTitle(.init(reason: "Grooming", version: 1)), "Plan written")
        XCTAssertEqual(TimelineEntry.planTitle(.init(reason: " Final check, round 1 ", version: 3)), "Plan changed: Final check, round 1")
        XCTAssertEqual(TimelineEntry.planTitle(.init(version: 2)), "Plan changed")
    }

    func testThePayloadReadsAPlansVersion() throws {
        let plan = try XCTUnwrap(try history().events.first { $0.id == "r1" })
        XCTAssertEqual(plan.payload.version, 2)
        XCTAssertEqual(plan.payload.reason, "The button keeps the word Release")
        // `by` is a word here, not a setter.
        XCTAssertNil(plan.payload.setter)
    }

    func testChecksTheAskAndAnInterventionAreOneLineEachFromTheirSummary() throws {
        let ask = try entry("a1")
        XCTAssertEqual([ask.kind.rawValue, ask.title, ask.actor], ["ask", "Ask recorded", "Symphony"])
        XCTAssertNil(ask.detail)

        // Two checks proved one after the other with the same words stay two lines.
        let proved = entries(try history()).filter { $0.kind == .checkProved }
        XCTAssertEqual(proved.map(\.eventIDs), [["k2"], ["k1"]])
        XCTAssertEqual(proved.map(\.title), ["Check proved", "Check proved"])
        XCTAssertEqual(proved.map(\.detail), [nil, nil])
        XCTAssertEqual(proved.first?.actor, "Implementation run 1")

        let waived = try entry("k3")
        XCTAssertEqual([waived.kind.rawValue, waived.title], ["checkWaived", "Check waived"])
        XCTAssertNil(waived.detail)

        let intervention = try entry("n1")
        XCTAssertEqual([intervention.kind.rawValue, intervention.title], ["intervention", "The Conductor of TP-1300 replanned this ticket"])
        XCTAssertNil(intervention.detail)
    }

    func testTheNewClassesHaveAGlyphAToneAndAWord() {
        let kinds: [TimelineEntry.Kind] = [.plan, .ask, .checkProved, .checkWaived, .intervention]
        XCTAssertEqual(kinds.map(\.symbol), ["doc.text.magnifyingglass", "text.quote", "checkmark.seal", "seal", "arrow.triangle.branch"])
        XCTAssertEqual(kinds.map(\.tone), [.status(.idle), .accent, .status(.done), .status(.idle), .status(.idle)])
        XCTAssertEqual(kinds.map(\.word), ["plan", "ask", "check proved", "check waived", "Conductor action"])
    }

    // MARK: - The Conductor's reply

    func testTheReplyIsDrawnUnderItsMessageAndIsNoEntryOfItsOwn() throws {
        let all = entries(try history())
        XCTAssertNil(all.first { $0.id == "r2" })

        let message = try entry("m1")
        XCTAssertEqual(message.kind, .message)
        XCTAssertEqual(message.title, "You wrote: \u{201C}Keep the button word Release.\u{201D}")
        XCTAssertEqual(message.eventIDs, ["m1", "r2"])
        // The reply stands where "Read by…" does on a ticket without a plan.
        XCTAssertNil(message.detail)
        XCTAssertFalse(message.waitsForRun)
        let reply = try XCTUnwrap(message.reply)
        XCTAssertEqual(reply.text, "Release stays. I added a check for the word.")
        XCTAssertEqual(reply.junction, .message)
        XCTAssertTrue(reply.isReply)
        XCTAssertEqual(reply.blocks.count, 1)
        XCTAssertEqual(reply.runTitle, "Conductor run 2")
        XCTAssertEqual(
            message.accessibilityLabel(time: "09:45"),
            "09:45, message, You wrote: \u{201C}Keep the button word Release.\u{201D}, by Tony, "
                + "Conductor, answering your message, Release stays. I added a check for the word."
        )
    }

    func testAMessageWithNoReplyYetWaitsOnTopForTheConductor() throws {
        let model = TimelineModel.build(try history(), reference: reference, calendar: utc)
        XCTAssertEqual(model.items.first?.id, "entry-m2")
        let waiting = try entry("m2")
        XCTAssertTrue(waiting.waitsForRun)
        XCTAssertNil(waiting.reply)
        XCTAssertEqual(waiting.detail, "The Conductor reads it next")
    }

    func testOnATicketWithoutAPlanAMessageWaitsForTheNextRunAsBefore() throws {
        let history = try page([
            #"{"id": "m1", "at": "2026-10-08T09:45:00Z", "type": "message.sent", "actor": {"kind": "person", "name": "Tony"}, "payload": {"text": "Hi."}, "summary": {"title": "You wrote"}, "read": null}"#,
        ])
        XCTAssertEqual(entries(history).first?.detail, "The next run reads it first")
    }

    func testAReplyServedUnderItsMessageIsRead() throws {
        let history = try page([
            #"""
            {"id": "m1", "at": "2026-10-08T09:45:00Z", "type": "message.sent", "actor": {"kind": "person", "name": "Tony"}, "payload": {"text": "Hi."},
             "summary": {"title": "You wrote"}, "read": null, "children": [
               {"id": "r1", "at": "2026-10-08T09:46:00Z", "type": "conductor.update", "parent": "m1", "payload": {"junction": "message", "text": "Hello."}, "new": true}
             ]}
            """#,
        ])
        let all = entries(history)
        XCTAssertEqual(all.map(\.id), ["m1"])
        XCTAssertEqual(all.first?.reply?.text, "Hello.")
        XCTAssertEqual(all.first?.isNew, false)
        // A reply newer than the person's last look marks its message new.
        let looked = TimelineModel.build(history, reference: reference, calendar: utc, lookedAt: reference.addingTimeInterval(-3600))
        XCTAssertEqual(looked.items.first?.isNew, true)
    }

    func testAReplyWhoseMessageThePageDoesNotHoldIsAnEntryOfItsOwn() throws {
        let history = try page([
            #"{"id": "r1", "at": "2026-10-08T09:46:00Z", "type": "conductor.update", "parent": "gone", "payload": {"junction": "message", "text": "Hello."}}"#,
        ])
        let all = entries(history)
        XCTAssertEqual(all.map(\.id), ["r1"])
        XCTAssertEqual(all.first?.conductor?.junctionWords, "answering your message")
    }

    // MARK: - A message of blocks alone

    func testAConductorUpdateWithBlocksAndNoWordsStillDraws() throws {
        let block = #"{"type": "budget", "tokens_used": 10, "tokens_cap": 20, "parts": []}"#
        let history = try page([
            #"{"id": "u1", "at": "2026-10-08T09:46:00Z", "type": "conductor.update", "payload": {"junction": "after_coding", "text": "", "blocks": [\#(block)]}}"#,
            #"{"id": "u2", "at": "2026-10-08T09:47:00Z", "type": "conductor.update", "payload": {"junction": "after_coding", "blocks": [\#(block)]}}"#,
            #"{"id": "u3", "at": "2026-10-08T09:48:00Z", "type": "conductor.update", "payload": {"junction": "after_coding", "text": "  "}}"#,
        ])
        let messages = history.events.map { ConductorMessage(event: $0) }
        XCTAssertEqual(messages.map { $0?.text }, ["", "", nil])
        XCTAssertEqual(messages.map { $0?.blocks.count }, [1, 1, nil])
        XCTAssertEqual(messages.first??.accessibilityLabel(time: "09:46"), "Conductor, after coding, 09:46")
        // Newest first: the update with nothing to say, then the two of the same block, which are the one write.
        XCTAssertEqual(entries(history).map { $0.conductor != nil }, [false, true])
        XCTAssertEqual(entries(history).map(\.eventIDs), [["u3"], ["u1", "u2"]])
    }
}
