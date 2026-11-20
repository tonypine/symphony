import Foundation
@testable import SymphonyBarCore
import XCTest

/// The ticket read's `brief`, `ticket` and `workspace`, and the ticket's decisions as the facts rail's Decisions panel
/// says them, from the fixtures in `Tests/Fixtures/facts-rail`: a ticket with every fact, one with fewer, and one
/// Symphony holds nothing of. The read's `note`, which an older Symphony still serves, is not read.
@MainActor
final class FactsRailDetailsTests: XCTestCase {
    private static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/facts-rail")

    private let reference = ISO8601DateFormatter().date(from: "2026-11-10T15:00:00Z")!

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func data(_ name: String) throws -> Data {
        try Data(contentsOf: Self.fixtures.appendingPathComponent("\(name).json"))
    }

    private func read(_ name: String) throws -> TicketDetailsRead {
        try XCTUnwrap(TicketDetailsRead.decode(try data(name)))
    }

    // MARK: - Decoding

    func testTheTicketReadDecodesTheTicketTheBriefAndTheWorkspace() throws {
        let read = try read("details")
        XCTAssertEqual(read.repoKey, "symphony")
        XCTAssertEqual(read.ticket, TicketRecordRead(
            title: "The facts rail's Note, Decisions and Details panels", phase: "In Progress", priority: 1,
            labels: ["skip-update-hold", "qa:fixture"],
            description: "## Problem\n\nThe brief is buried in the Details panel.\n\n## Acceptance\n\n- The brief is on top of the page."
        ))
        XCTAssertEqual(read.brief?.at, ISO8601DateFormatter().date(from: "2026-11-10T09:12:00Z"))
        XCTAssertEqual(read.brief?.runID, "run-1")
        XCTAssertEqual(read.brief?.runKind, "implementation")
        XCTAssertNotNil(read.brief?.walkthrough)
        XCTAssertEqual(read.workspace, TicketWorkspaceRead(path: "/Users/tonypine/symphony-workspaces/symphony/TP-1447"))
    }

    func testAReadSymphonyHoldsNothingOfDecodesEmptyAndAnythingButAnObjectIsNone() throws {
        let read = try read("details-empty")
        XCTAssertEqual(read, TicketDetailsRead(ticket: TicketRecordRead()))
        XCTAssertEqual(TicketDetailsRead.decode(Data("{}".utf8)), TicketDetailsRead())
        XCTAssertEqual(
            TicketDetailsRead.decode(Data(#"{"note":{"text":null},"brief":{},"ticket":{}}"#.utf8)),
            TicketDetailsRead(ticket: TicketRecordRead(), brief: TicketBriefRead(text: ""))
        )
        XCTAssertNil(TicketDetailsRead.decode(Data("[]".utf8)))
        // A brief whose author isn't an object still reads, without a run.
        let odd = TicketDetailsRead.decode(Data(#"{"brief":{"text":"It works.","by":"someone"}}"#.utf8))
        XCTAssertEqual(odd?.brief, TicketBriefRead(text: "It works."))
    }

    // MARK: - The Decisions panel

    func testDecisionsReadNewestFirstEachTheDecisionAndWhoAnsweredWhen() {
        let model = DecisionsPanelModel.build([
            TicketDecision(
                id: "D1", date: "2026-11-09", title: "Keep the facts rail at 340 pt",
                question: "How wide is the rail on a laptop?", answer: "340 pt, as the catalog shows.", scope: "The rail's width is fixed."
            ),
            TicketDecision(id: "D2", date: "2026-11-10", title: "  ", answer: " Fold the agent description by default. "),
            TicketDecision(id: "D3", date: "2026-11-06", answer: "Keep Release."),
        ], reference: reference, calendar: utc)
        XCTAssertFalse(model.isEmpty)
        XCTAssertEqual(model.rows.map(\.id), ["D3", "D2", "D1"])
        XCTAssertEqual(model.rows[1], DecisionsPanelModel.Row(
            id: "D2", title: "Fold the agent description by default.", byline: "You · today",
            accessibilityLabel: "Decision D2, Fold the agent description by default., answered by you, today"
        ))
        XCTAssertEqual(model.rows[2].title, "Keep the facts rail at 340 pt")
        XCTAssertEqual(model.rows[2].byline, "You · yesterday")
        XCTAssertEqual(model.rows[0].byline, "You · Fri 6 Nov")
    }

    func testADecisionWithoutADayIsYoursAloneAndNoDecisionsIsNoPanel() {
        XCTAssertTrue(DecisionsPanelModel.build([]).isEmpty)
        let row = DecisionsPanelModel.build([TicketDecision(id: "D3", answer: "Yes.")]).rows[0]
        XCTAssertEqual(row.byline, "You")
        XCTAssertEqual(row.accessibilityLabel, "Decision D3, Yes., answered by you")
        XCTAssertEqual(DecisionsPanelModel.day("2025-03-02", reference: reference, calendar: utc), "2 Mar 2025")
        XCTAssertEqual(DecisionsPanelModel.day("last week", reference: reference, calendar: utc), "last week")
    }
}
