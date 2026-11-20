import Foundation
@testable import SymphonyBarCore
import XCTest

/// The brief on top of the ticket page (TP-1504), from the fixtures in `Tests/Fixtures/facts-rail`: the newest brief
/// under a label naming the run that wrote it and when, with its walkthrough and what was asked; "Asked for" and the
/// ticket's goal before any run wrote one; nothing for a ticket with neither. Code and paths in it are set apart.
@MainActor
final class BriefPanelTests: XCTestCase {
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

    private func runs() throws -> [String: TicketEventsPayload.Run] {
        try XCTUnwrap(TicketEventsPayload.decode(try data("details-events"))).runs
    }

    // MARK: - The brief

    func testTheBriefNamesTheRunThatWroteItAndWhenWithItsWalkthroughAndWhatWasAsked() throws {
        let model = try XCTUnwrap(BriefPanelModel.build(try read("details"), runs: try runs(), reference: reference, calendar: utc))
        XCTAssertEqual(model.kind, .brief)
        XCTAssertTrue(model.folds)
        XCTAssertEqual(model.title, "Brief")
        XCTAssertEqual(model.note, "written by Implementation run 1 at 09:12")
        XCTAssertTrue(model.text.hasPrefix("Adds the last three panels"))
        XCTAssertTrue(model.walkthrough?.hasPrefix("Write a note and save it") ?? false)
        XCTAssertEqual(model.asked, "## Problem\n\nThe brief is buried in the Details panel.\n\n## Acceptance\n\n- The brief is on top of the page.")
    }

    func testALaterRunsBriefNamesThatRun() {
        let runs = ["run-9": TicketEventsPayload.Run(runID: "run-9", runKind: "rework", runNumber: 2)]
        let read = TicketDetailsRead(brief: TicketBriefRead(
            text: "Now it folds.", at: ISO8601DateFormatter().date(from: "2026-11-09T18:05:00Z"), runID: "run-9", runKind: "rework"
        ))
        let model = BriefPanelModel.build(read, runs: runs, reference: reference, calendar: utc)
        XCTAssertEqual(model?.note, "written by Rework run 2 yesterday at 18:05")
        XCTAssertNil(model?.walkthrough)
        XCTAssertNil(model?.asked)
    }

    func testTheLabelSaysWhatTheReadKnowsOfWhoAndWhen() {
        func note(_ brief: TicketBriefRead) -> String? {
            BriefPanelModel.build(TicketDetailsRead(brief: brief), runs: [:], reference: reference, calendar: utc)?.note
        }
        // A run the feed doesn't hold yet is named by its kind.
        XCTAssertEqual(note(TicketBriefRead(text: "It works.", runID: "gone", runKind: "implementation")), "written by Implementation run")
        XCTAssertEqual(
            note(TicketBriefRead(text: "It works.", at: ISO8601DateFormatter().date(from: "2026-11-06T08:00:00Z"))),
            "written on Fri 6 Nov at 08:00"
        )
        XCTAssertNil(note(TicketBriefRead(text: "It works.", walkthrough: " ")))
    }

    // MARK: - Asked for

    func testBeforeAnyBriefTheGoalIsAskedForWithoutAFold() throws {
        let model = try XCTUnwrap(BriefPanelModel.build(try read("details-unread"), runs: [:], reference: reference, calendar: utc))
        XCTAssertEqual(model, BriefPanelModel(
            kind: .askedFor, title: "Asked for", note: "no run has written a brief yet", text: "Draw the ticket page in a laptop's window.",
            walkthrough: nil, asked: nil
        ))
        XCTAssertFalse(model.folds)
        // A blank brief is no brief.
        let blank = TicketDetailsRead(ticket: TicketRecordRead(description: "## Goal\nShip it."), brief: TicketBriefRead(text: "  "))
        XCTAssertEqual(BriefPanelModel.build(blank, runs: [:], reference: reference, calendar: utc)?.text, "Ship it.")
    }

    func testATicketWithNeitherABriefNorADescriptionHasNoPanel() throws {
        XCTAssertNil(BriefPanelModel.build(try read("details-empty"), runs: [:], reference: reference, calendar: utc))
        XCTAssertNil(BriefPanelModel.build(nil, runs: [:], reference: reference, calendar: utc))
        let blank = TicketDetailsRead(ticket: TicketRecordRead(description: " \n## Problem\n\n## Design\n "))
        XCTAssertNil(BriefPanelModel.build(blank, runs: [:], reference: reference, calendar: utc))
    }

    func testTheGoalIsTheFirstSectionWithText() {
        XCTAssertEqual(BriefPanelModel.goal(of: "## Problem\n\nIt is buried.\n\n## Design\n\nThe catalog."), "It is buried.")
        XCTAssertEqual(BriefPanelModel.goal(of: "Before any heading.\n## Problem\nLater."), "Before any heading.")
        XCTAssertEqual(BriefPanelModel.goal(of: "## \n#hashtag first\n## Next\nNo."), "## \n#hashtag first")
        XCTAssertEqual(BriefPanelModel.goal(of: "####### Seven is not a heading"), "####### Seven is not a heading")
        XCTAssertNil(BriefPanelModel.goal(of: "  "))
    }

    func testTheFoldSaysWhatItDoes() {
        XCTAssertEqual(BriefPanelModel.foldTitle(open: false), "Read all of it, with the walkthrough")
        XCTAssertEqual(BriefPanelModel.foldTitle(open: true), "Show less")
    }

    // MARK: - Code and paths

    func testCodeAndPathsAreSetApartFromTheProse() {
        typealias Span = ReadingSpans.Span
        XCTAssertEqual(
            ReadingSpans.split("Open docs/design/catalog/index.html and run `mix test` in Entries.swift."),
            [
                Span("Open ", code: false), Span("docs/design/catalog/index.html", code: true), Span(" and run ", code: false),
                Span("mix test", code: true), Span(" in ", code: false), Span("Entries.swift", code: true), Span(".", code: false),
            ]
        )
        XCTAssertEqual(ReadingSpans.split("Keep ~/Library and /tmp/x as paths."), [
            Span("Keep ", code: false), Span("~/Library", code: true), Span(" and ", code: false), Span("/tmp/x", code: true),
            Span(" as paths.", code: false),
        ])
        XCTAssertEqual(ReadingSpans.split("Read and/or write."), [Span("Read and/or write.", code: false)])
        XCTAssertEqual(ReadingSpans.split(""), [])
        XCTAssertEqual(ReadingSpans.codeScale, 0.85)
    }
}
