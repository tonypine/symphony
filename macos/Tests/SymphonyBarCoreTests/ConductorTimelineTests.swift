import Foundation
@testable import SymphonyBarCore
import XCTest

/// The Conductor on the timeline, from `Tests/Fixtures/timeline/conductor.json`: its update for the person is an entry
/// of its own that always shows, with its whole text; its instructions to the next run and its own run fold behind
/// "Show all events".
final class ConductorTimelineTests: XCTestCase {
    private static let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/timeline/conductor.json")

    private let reference = ISO8601DateFormatter().date(from: "2026-10-08T10:27:00Z")!

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func model() throws -> TimelineModel {
        let history = try XCTUnwrap(TicketEventsPayload.decode(Data(contentsOf: Self.fixture)))
        return TimelineModel.build(history, reference: reference, calendar: utc)
    }

    private func entries(_ model: TimelineModel) -> [TimelineEntry] {
        model.items.compactMap { item in
            if case let .entry(entry) = item { return entry }
            return nil
        }
    }

    func testTheUpdateShowsWholeAndTheInstructionsAndTheConductorsRunFold() throws {
        let all = try model()
        // The phase entered, the instructions and the Conductor's run.
        XCTAssertEqual(all.mechanicalCount, 3)

        let folded = all.showing(allEvents: false)
        XCTAssertEqual(folded.mechanicalCount, 0)
        XCTAssertEqual(folded.items.map(\.id), ["entry-c2", "run-run-1"])
        let update = try XCTUnwrap(entries(folded).first)
        XCTAssertEqual(update.kind, .update)
        XCTAssertEqual(update.title, "Update")
        XCTAssertEqual(
            update.detail,
            "The first run built the Inbox filter and its tests pass.\nIt left the empty state untouched, which the walkthrough's third step "
                + "needs, so Code Review looks at that first."
        )
        XCTAssertFalse(update.isMechanical)
        XCTAssertEqual(update.actor, "Conductor run 1")

        let shown = all.showing(allEvents: true)
        XCTAssertEqual(shown, all)
        XCTAssertEqual(shown.items.map(\.id), ["entry-c3", "entry-c2", "run-run-c1", "entry-p1", "run-run-1"])
        let conductorRun = try XCTUnwrap(shown.run("run-c1"))
        XCTAssertTrue(conductorRun.isMechanical)
        XCTAssertEqual(conductorRun.title, "Conductor run 1")
        XCTAssertFalse(try XCTUnwrap(shown.run("run-1")).isMechanical)
        let instructions = try XCTUnwrap(entries(shown).first { $0.id == "c3" })
        XCTAssertEqual(instructions.kind, .note)
        XCTAssertTrue(instructions.isMechanical)
        XCTAssertEqual(instructions.title, "Conductor instructions")
        XCTAssertEqual(instructions.detail, "Check the empty state against the walkthrough's third step.\nThe filter's tests already pass on this head.")
    }

    func testTheUpdateSaysUpdateWhateverTheSummaryAndHasItsOwnGlyph() throws {
        let page = #"{"timeline":[{"id":"u1","at":"2026-10-08T09:00:00Z","type":"conductor.update","actor":{"kind":"machine"},"payload":{"junction":"before_merge","text":"QA passed.","refs":[]},"artifacts":[],"children":[]}]}"#
        let history = try XCTUnwrap(TicketEventsPayload.decode(Data(page.utf8)))
        let entry = try XCTUnwrap(entries(TimelineModel.build(history, reference: reference, calendar: utc)).first)
        XCTAssertEqual(entry.title, TimelineEntry.updateTitle)
        XCTAssertEqual(entry.detail, "QA passed.")
        XCTAssertEqual(entry.actor, "Symphony")
        XCTAssertEqual(TimelineEntry.Kind.update.symbol, "text.bubble")
        XCTAssertEqual(TimelineEntry.Kind.update.tone, .status(.idle))
        XCTAssertEqual(TimelineEntry.Kind.update.word, "update")
    }

    func testTheConductorsLiveTurnIsNeverTheRunNow() throws {
        func run(_ id: String, kind: String, at: String) -> String {
            #"{"kind":"run","run_id":"\#(id)","run_kind":"\#(kind)","run_number":1,"status":"running","started_at":"2026-10-08T\#(at)Z","events":[]}"#
        }
        let page = #"{"timeline":[\#(run("review-1", kind: "code_review", at: "10:00:00")),\#(run("c1", kind: "conductor", at: "10:00:05"))]}"#
        let history = try XCTUnwrap(TicketEventsPayload.decode(Data(page.utf8)))
        let model = TimelineModel.build(history, reference: reference, calendar: utc)
        XCTAssertEqual(model.items.first?.run?.id, "c1", "the newer live run is on top")
        XCTAssertEqual(model.runNow?.id, "review-1")
        XCTAssertEqual(model.showing(allEvents: false).runNow?.id, "review-1")

        let alone = #"{"timeline":[\#(run("c1", kind: "conductor", at: "10:00:05"))]}"#
        let only = TimelineModel.build(try XCTUnwrap(TicketEventsPayload.decode(Data(alone.utf8))), reference: reference, calendar: utc)
        XCTAssertNil(only.runNow)
    }
}
