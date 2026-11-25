import Foundation
@testable import SymphonyBarCore
import XCTest

/// The plan on top of a groomed ticket's page, from `Tests/Fixtures/director-app/ticket-page` (TP-1247, groomed, with
/// a check in each state and a message the Conductor answered; TP-1244, with no plan): the ticket read's `plan`,
/// `checks` and `asks`, what the Plan panel says from them, and the page that draws it in the Brief's place.
@MainActor
final class PlanPanelTests: XCTestCase {
    private static let api = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/director-app/ticket-page/api/v1")

    private let utc = TimeZone(identifier: "UTC")!

    private func data(_ path: String) throws -> Data {
        try Data(contentsOf: Self.api.appendingPathComponent(path))
    }

    private func read(_ identifier: String) throws -> TicketDetailsRead {
        try XCTUnwrap(TicketDetailsRead.decode(try data("\(identifier).json")))
    }

    private func page(_ identifier: String, state: String? = nil) throws -> TicketPage {
        TicketPage(
            identifier: identifier,
            sources: TicketPage.Sources(
                state: try data(["state", state, "json"].compactMap { $0 }.joined(separator: ".")), issue: try data([identifier, state, "json"].compactMap { $0 }.joined(separator: ".")),
                events: TicketEventsPayload.decode(try data("repos/symphony/tickets/\(identifier)/events.json"))
            ),
            timeZone: utc
        )
    }

    private func decode(_ json: String) throws -> TicketDetailsRead {
        try XCTUnwrap(TicketDetailsRead.decode(Data(json.utf8)))
    }

    // MARK: - The ticket read

    func testTheTicketReadHoldsThePlanItsChecksAndTheAsks() throws {
        let read = try read("TP-1247")
        let plan = try XCTUnwrap(read.plan)
        XCTAssertEqual(plan.version, 2)
        XCTAssertEqual(plan.at, ISO8601DateFormatter().date(from: "2026-10-08T09:45:40Z"))
        XCTAssertEqual([plan.reason, plan.by, plan.shape], ["The button keeps the word Release", "recalibration", "single"])
        XCTAssertEqual(plan.layers, ["screen", "engine"])
        XCTAssertTrue(plan.summary.hasPrefix("Add who paused the ticket to the paused line"))
        XCTAssertTrue(plan.text.hasPrefix("## Approach"))

        XCTAssertEqual(read.checks.map(\.id), ["c1", "c2", "c3", "c4", "c5", "c6"])
        XCTAssertEqual(read.checks.map(\.state), [.proved, .proved, .open, .open, .proved, .waived])
        XCTAssertEqual(read.checks.map(\.kind), ["outcome", "outcome", "outcome", "qa", "qa", "evidence"])
        XCTAssertEqual(read.checks.map(\.proof), ["test", "test", "test", "qa", "design", "attached"])
        XCTAssertEqual(read.checks[0].provedBy, .init(by: "test", test: "PausedLineTests › says who paused it"))
        XCTAssertEqual(read.checks[5].waived, .init(reason: "No test can hold a real pause open, and QA walks the same line."))
        XCTAssertNil(read.checks[0].waived)
        XCTAssertEqual(read.checks[4].provedBy, .init(by: "design", details: "Matches the Gallery story at 2560 pt."))
        XCTAssertNil(read.checks[2].provedBy)

        XCTAssertEqual(read.asks.map(\.source), ["linear", "message"])
        XCTAssertEqual(read.asks.map(\.from), [nil, "m1"])
        XCTAssertEqual(read.asks.last?.text, "Keep the button word Release.")
    }

    func testATicketWithNoPlanReadsNoneAndAnOlderSymphonysReadToo() throws {
        let ungroomed = try decode(#"{"repo_key": "symphony", "plan": null, "checks": [], "asks": []}"#)
        XCTAssertNil(ungroomed.plan)
        XCTAssertEqual(ungroomed.checks, [])
        XCTAssertEqual(ungroomed.asks, [])
        let older = try read("TP-1244")
        XCTAssertNil(older.plan)
        XCTAssertEqual(older.checks, [])
        XCTAssertNotNil(older.brief)
    }

    func testAFieldOfAnotherShapeNeverFailsTheRead() throws {
        let read = try decode(#"""
            {"repo_key": "symphony", "brief": {"text": "Kept."},
             "plan": {"version": "two", "summary": 7, "text": "Do it.", "layers": "screen"},
             "checks": [{"id": "c1", "statement": "Stays", "state": "The app is paused", "proved_by": {"by": "qa"}},
                        {"id": "c2", "statement": "Open still", "state": "somewhere"}, {"statement": "No id"}, "c4",
                        {"id": "c5", "statement": "Let go", "waived": {"reason": "Not provable"}}],
             "asks": {"text": "not a list"}}
            """#)
        XCTAssertEqual(read.brief?.text, "Kept.")
        XCTAssertEqual(read.plan, TicketPlanRead(text: "Do it."))
        // A state that is none of the three is what the check's own fields say: proved, waived, else open.
        XCTAssertEqual(read.checks.map(\.id), ["c1", "c2", "c5"])
        XCTAssertEqual(read.checks.map(\.state), [.proved, .open, .waived])
        XCTAssertEqual(read.asks, [])
        XCTAssertNil(try decode(#"{"plan": "soon"}"#).plan)
    }

    // MARK: - The panel

    func testThePanelSaysTheSummaryThenOneLinePerCheckAndHowFarTheyAre() throws {
        let model = try XCTUnwrap(PlanPanelModel.build(try read("TP-1247")))
        XCTAssertEqual(model.title, "Plan")
        XCTAssertEqual(model.note, "3 of 6 checks proved")
        XCTAssertEqual(model.line, "Plan · 3 of 6 checks proved")
        XCTAssertEqual(
            model.summary,
            "Add who paused the ticket to the paused line, after the reason and the time. A rule's pause names the rule. The button keeps the word Release."
        )
        XCTAssertEqual(model.checks.map(\.id), ["c1", "c2", "c3", "c4", "c5", "c6"])
        XCTAssertEqual(model.checks.map(\.proof), ["Test", "Test", "Test", "QA", "Design", "Waived"])
        XCTAssertEqual(
            model.checks.map(\.symbol),
            ["checkmark.circle.fill", "checkmark.circle.fill", "circle", "circle", "checkmark.circle.fill", "minus.circle"]
        )
        XCTAssertEqual(model.checks[0].help, "PausedLineTests › says who paused it")
        XCTAssertEqual(model.checks[4].help, "Matches the Gallery story at 2560 pt.")
        XCTAssertNil(model.checks[2].help)
        XCTAssertEqual(model.checks[5].help, "No test can hold a real pause open, and QA walks the same line.")
        XCTAssertEqual(model.checks[0].accessibilityLabel, "Proved, The paused line says who paused the ticket, after why and since when, Test")
        XCTAssertEqual(model.checks[2].accessibilityLabel, "Open, The button on the paused line reads Release, Test")
        XCTAssertEqual(
            model.checks[5].accessibilityLabel,
            "Waived, A recording of a real pause being released, No test can hold a real pause open, and QA walks the same line."
        )
        XCTAssertFalse(model.isEmpty)
    }

    func testUnfoldedItShowsThePlanForTheRunsAndWhatWasAsked() throws {
        let model = try XCTUnwrap(PlanPanelModel.build(try read("TP-1247")))
        XCTAssertTrue(model.folds)
        // The plan's Markdown reads as prose, as the brief's does.
        XCTAssertTrue(try XCTUnwrap(model.text).hasPrefix("Approach\n\nRead who set the pause from the ticket read's `pause.set_by`"))
        XCTAssertEqual(
            model.asked,
            "The paused line should say who paused the ticket, after why and since when.\n\nKeep the button word Release."
        )
        XCTAssertEqual(PlanPanelModel.foldTitle(open: false), "Show more")
        XCTAssertEqual(PlanPanelModel.foldTitle(open: true), "Show less")
    }

    func testTheProgressCountsProvedChecksAndAPlanWithoutChecksHasNone() {
        XCTAssertNil(PlanPanelModel.progress([]))
        XCTAssertEqual(PlanPanelModel.progress([TicketCheckRead(id: "c1", statement: "One")]), "0 of 1 check proved")
        XCTAssertEqual(
            PlanPanelModel.progress([
                TicketCheckRead(id: "c1", statement: "One", state: .proved), TicketCheckRead(id: "c2", statement: "Two", state: .waived),
            ]),
            "1 of 2 checks proved"
        )
        XCTAssertEqual(["test", "qa", "design", "attached", "ci", "magic", nil].map(PlanPanelModel.proofWord), ["Test", "QA", "Design", "Attached", "CI", nil, nil])
    }

    func testAPlanDrawsOnlyWhatItHolds() throws {
        let bare = try XCTUnwrap(PlanPanelModel.build(TicketDetailsRead(plan: TicketPlanRead(summary: " One change. "))))
        XCTAssertEqual(bare.summary, "One change.")
        XCTAssertNil(bare.note)
        XCTAssertEqual(bare.line, "Plan")
        XCTAssertEqual(bare.checks, [])
        XCTAssertFalse(bare.folds)
        XCTAssertFalse(bare.isEmpty)

        let empty = try XCTUnwrap(PlanPanelModel.build(TicketDetailsRead(plan: TicketPlanRead())))
        XCTAssertTrue(empty.isEmpty)
        // A proved check with no proof named by its event says how the plan meant it proved.
        let check = PlanPanelModel.check(TicketCheckRead(id: "c1", statement: "S", proof: "qa", state: .proved, provedBy: .init()))
        XCTAssertEqual(check.proof, "QA")
    }

    func testATicketWithNoPlanHasNoPlanPanel() throws {
        XCTAssertNil(PlanPanelModel.build(try read("TP-1244")))
        XCTAssertNil(PlanPanelModel.build(nil))
    }

    // MARK: - The page

    func testAGroomedTicketsPageIsGroomedAndItsBoxKeepsItsWords() throws {
        XCTAssertTrue(try page("TP-1247").isGroomed)
        XCTAssertTrue(try page("TP-1247").takesMessages)
        XCTAssertFalse(try page("TP-1244").isGroomed)
        XCTAssertEqual(TicketMessageComposer.placeholder, "Write to the ticket.")
        XCTAssertEqual(TicketMessageComposer.sentAnnouncement, "Message sent.")
    }

    func testAFinishedGroomedTicketStillTakesAMessageAndOneWithNoPlanDoesNot() throws {
        // The ticket once moved to Done, as the fixture serves it after the move.
        let finished = try page("TP-1247", state: "after-move")
        XCTAssertEqual(finished.phaseName, "Done")
        guard case .done = finished.phase else { return XCTFail("The moved ticket's page is not done") }
        XCTAssertTrue(finished.isGroomed)
        XCTAssertTrue(finished.takesMessages)
        var page = try page("TP-1247")
        for phase in ["Done", "Canceled", "Cancelled"] {
            page.phaseName = phase
            XCTAssertTrue(page.takesMessages, phase)
        }
        page.phase = .done(pullRequest: nil, mergedAt: nil)
        XCTAssertTrue(page.takesMessages)
        // With no plan a finished ticket has no box, as before.
        page.detailsRead?.plan = nil
        XCTAssertFalse(page.takesMessages)
        XCTAssertEqual(try self.page("TP-1246").phaseName, "Done")
        XCTAssertFalse(try self.page("TP-1246").takesMessages)
    }

    func testAWaivedCheckSaysWhyOnItsLineAndTheOthersDoNot() throws {
        let waived = PlanPanelModel.check(
            TicketCheckRead(id: "c1", statement: "S", proof: "attached", state: .waived, waived: .init(reason: " Out of scope. "))
        )
        XCTAssertEqual(waived.reason, "Out of scope.")
        XCTAssertEqual(waived.proof, "Waived")
        XCTAssertEqual(waived.accessibilityLabel, "Waived, S, Out of scope.")
        XCTAssertNil(PlanPanelModel.check(TicketCheckRead(id: "c1", statement: "S", state: .waived, waived: .init(reason: " "))).reason)
        XCTAssertNil(PlanPanelModel.check(TicketCheckRead(id: "c1", statement: "S", state: .waived)).reason)
        // A check not waived has no reason, whatever its read holds.
        let proved = PlanPanelModel.check(
            TicketCheckRead(id: "c2", statement: "S", proof: "qa", state: .proved, provedBy: .init(by: "qa"), waived: .init(reason: "Old"))
        )
        XCTAssertNil(proved.reason)
        XCTAssertEqual(proved.accessibilityLabel, "Proved, S, QA")
        let fixture = try XCTUnwrap(PlanPanelModel.build(try read("TP-1247")))
        XCTAssertEqual(fixture.checks.filter { $0.reason != nil }.map(\.state), [.waived])
    }

    func testTheGroomedTicketsTimelineHoldsThePlanAndTheReplyUnderItsMessage() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let model = try page("TP-1247").timelineModel(calendar: calendar).showing(allEvents: false)
        let entries: [TimelineEntry] = model.items.compactMap { item in
            if case let .entry(entry) = item { return entry }
            return nil
        }
        XCTAssertEqual(
            entries.map(\.title),
            [
                "Plan changed: The button keeps the word Release", "Ask recorded", "You wrote: \u{201C}Keep the button word Release.\u{201D}",
                "Check c6 waived", "Check c5 proved against the design", "Check c2 proved by a test", "Check c1 proved by a test",
                "Update", "Plan written", "Ask recorded",
            ]
        )
        let message = try XCTUnwrap(entries.first { $0.kind == .message })
        XCTAssertEqual(message.reply?.blocks.count, 1)
        XCTAssertTrue(try XCTUnwrap(message.reply?.text).hasPrefix("Release stays."))
        XCTAssertFalse(message.waitsForRun)
        XCTAssertEqual(entries.first { $0.title == "Update" }?.conductor?.junctionWords, "grooming")
    }

    // MARK: - Sending

    func testAMessageGoesToControlMessageAndSymphonysEventAnswerIsDone() throws {
        let action = ControlAction.message(repoKey: "symphony", identifier: "TP-1247", text: "And keep the times at 11 pt.")
        let request = ControlAPI.request(action, base: APIFixtures.baseURL, token: APIFixtures.token)
        XCTAssertEqual(request.url?.path, "/api/v1/control/message")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: String])
        XCTAssertEqual(body, ["repo_key": "symphony", "issue_identifier": "TP-1247", "text": "And keep the times at 11 pt."])
        XCTAssertEqual(ControlAPI.result(action, statusCode: 200, data: try data("control/message.json")), .done)
        XCTAssertEqual(
            ControlAPI.result(action, statusCode: 422, data: Data(#"{"error": {"message": "text is too long"}}"#.utf8)),
            .failed("Couldn't send the message to TP-1247: text is too long (HTTP 422)")
        )
    }
}
