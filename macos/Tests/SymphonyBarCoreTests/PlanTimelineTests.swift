import Foundation
@testable import SymphonyBarCore
import XCTest

/// A groomed ticket's timeline, from `Tests/Fixtures/timeline/plan.json`: the plan's events are one line each, a
/// person's message holds the Conductor's reply under it, and a message with no reply yet waits on top until the ticket moves on.
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

    func testAMessageWithNoReplyYetWaitsOnTopWithNoLineOfItsOwn() throws {
        let model = TimelineModel.build(try history(), reference: reference, calendar: utc)
        XCTAssertEqual(model.items.first?.id, "entry-m2")
        let waiting = try entry("m2")
        XCTAssertTrue(waiting.waitsForRun)
        XCTAssertNil(waiting.reply)
        XCTAssertNil(waiting.detail)
    }

    // MARK: - A message nothing answers

    private static let plan = #"{"id": "p1", "at": "2026-10-08T09:00:00Z", "type": "plan.written", "payload": {"version": 1}}"#

    private func sent(_ id: String, at: String, read: String = "null") -> String {
        #"{"id": "\#(id)", "at": "2026-10-08T\#(at)Z", "type": "message.sent", "actor": {"kind": "person", "name": "Tony"}, "#
            + #""payload": {"text": "Hi."}, "summary": {"title": "You wrote"}, "read": \#(read)}"#
    }

    private func update(_ id: String, at: String, junction: String = "after_coding", parent: String? = nil, payload: String = #""text": "Noted.""#) -> String {
        let parent = parent.map { #""parent": "\#($0)", "# } ?? ""
        return #"{"id": "\#(id)", "at": "2026-10-08T\#(at)Z", "type": "conductor.update", \#(parent)"payload": {"junction": "\#(junction)", \#(payload)}}"#
    }

    private func message(_ id: String, in events: [String]) throws -> TimelineEntry {
        try XCTUnwrap(entries(try page(events)).first { $0.id == id })
    }

    func testAMessageNoOneAnswersLeavesTheTopOnceTheConductorSpeaksLater() throws {
        // Within a few minutes the message still waits; past them the Conductor's next update lets it go.
        XCTAssertTrue(try message("m1", in: [Self.plan, sent("m1", at: "09:45:00"), update("u1", at: "09:49:00")]).waitsForRun)
        let released = try message("m1", in: [Self.plan, sent("m1", at: "09:45:00"), update("u1", at: "09:51:00")])
        XCTAssertFalse(released.waitsForRun)
        XCTAssertNil(released.reply)
        XCTAssertNil(released.detail)
        let model = TimelineModel.build(
            try page([Self.plan, sent("m1", at: "09:45:00"), update("u1", at: "09:51:00")]), reference: reference, calendar: utc
        )
        XCTAssertEqual(model.items.map(\.id), ["entry-u1", "entry-m1", "entry-p1"])
    }

    func testAMessageNoOneAnswersLeavesTheTopOnceARunMovesOnOrARunReadsIt() throws {
        let started = #"{"id": "s1", "at": "2026-10-08T09:52:00Z", "type": "run.started", "run_id": "run-9", "payload": {"kind": "implementation"}}"#
        XCTAssertFalse(try message("m1", in: [Self.plan, sent("m1", at: "09:45:00"), started]).waitsForRun)
        // An event of no run and not the Conductor's keeps it waiting, however late.
        let moved = #"{"id": "x1", "at": "2026-10-08T10:20:00Z", "type": "phase.entered", "payload": {"to": "QA"}, "summary": {"title": "Moved to QA"}}"#
        XCTAssertTrue(try message("m1", in: [Self.plan, sent("m1", at: "09:45:00"), moved]).waitsForRun)
        // What happened before the message never lets it go.
        XCTAssertTrue(try message("m1", in: [Self.plan, update("u0", at: "09:10:00"), sent("m1", at: "09:45:00")]).waitsForRun)
        // A run that read it (`message.read`, the message's `read`) unpins it as on a ticket with no plan.
        let read = #"{"run_id": "run-9", "run": "Implementation run 2", "at": "2026-10-08T09:46:00Z"}"#
        let readOne = try message("m1", in: [Self.plan, sent("m1", at: "09:45:00", read: read)])
        XCTAssertFalse(readOne.waitsForRun)
        XCTAssertEqual(readOne.detail, "Read by Implementation run 2 at 09:46")
    }

    func testOnATicketWithNoPlanALaterUpdateLeavesTheMessageOnTop() throws {
        XCTAssertTrue(try message("m1", in: [sent("m1", at: "09:45:00"), update("u1", at: "09:51:00")]).waitsForRun)
    }

    func testALateReplyStillDrawsUnderItsMessage() throws {
        let late = try message("m1", in: [
            Self.plan, sent("m1", at: "09:45:00"), update("u1", at: "09:51:00"),
            update("r1", at: "09:58:00", junction: "message", parent: "m1", payload: #""text": "Hello.""#),
        ])
        XCTAssertFalse(late.waitsForRun)
        XCTAssertEqual(late.reply?.text, "Hello.")
    }

    // MARK: - Replies

    func testAReplyOfBlocksAloneDrawsUnderItsMessage() throws {
        let block = #"{"type": "budget", "tokens_used": 10, "tokens_cap": 20, "parts": []}"#
        let answered = try message("m1", in: [
            Self.plan, sent("m1", at: "09:45:00"),
            update("r1", at: "09:46:00", junction: "message", parent: "m1", payload: #""text": "", "blocks": [\#(block)]"#),
        ])
        let reply = try XCTUnwrap(answered.reply)
        XCTAssertEqual(reply.text, "")
        XCTAssertEqual(reply.blocks.count, 1)
        XCTAssertFalse(answered.waitsForRun)
        XCTAssertEqual(answered.eventIDs, ["m1", "r1"])
    }

    func testTwoMessagesEachHoldTheirOwnReplyInOrder() throws {
        let events = [
            Self.plan, sent("m1", at: "09:45:00"), sent("m2", at: "09:46:00"),
            update("r2", at: "09:47:00", junction: "message", parent: "m2", payload: #""text": "Second.""#),
            update("r1", at: "09:48:00", junction: "message", parent: "m1", payload: #""text": "First.""#),
        ]
        let all = entries(try page(events))
        // Newest first, each message where it was written, its reply under it and no entry of its own.
        XCTAssertEqual(all.map(\.id), ["m2", "m1", "p1"])
        XCTAssertEqual(all.map { $0.reply?.text }, ["Second.", "First.", nil])
        XCTAssertEqual(all.map(\.eventIDs), [["m2", "r2"], ["m1", "r1"], ["p1"]])
        XCTAssertEqual(all.map(\.waitsForRun), [false, false, false])
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
