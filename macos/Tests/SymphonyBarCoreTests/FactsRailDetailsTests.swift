import Foundation
@testable import SymphonyBarCore
import XCTest

/// The ticket read's `note`, `brief`, `ticket`, `workspace` and `moves.note`, the ticket's decisions and its runs'
/// models as the facts rail's Note for the next run, Decisions and Details panels say them, from the fixtures in
/// `Tests/Fixtures/facts-rail`: a ticket with a note a run read, one with a note no run read yet, and one Symphony holds
/// nothing of.
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

    private func runs() throws -> [String: TicketEventsPayload.Run] {
        try XCTUnwrap(TicketEventsPayload.decode(try data("details-events"))).runs
    }

    private func note(_ name: String) throws -> NotePanelModel {
        let read = try read(name)
        return NotePanelModel.build(note: read.note, move: read.noteMove, runs: try runs(), reference: reference, calendar: utc)
    }

    // MARK: - Decoding

    func testTheTicketReadDecodesTheTicketTheNoteTheBriefTheWorkspaceAndTheNoteMove() throws {
        let read = try read("details")
        XCTAssertEqual(read.repoKey, "symphony")
        XCTAssertEqual(read.ticket, TicketRecordRead(
            title: "The facts rail's Note, Decisions and Details panels", phase: "In Progress", priority: 1,
            labels: ["skip-update-hold", "qa:fixture"]
        ))
        XCTAssertEqual(read.note?.id, "01M746NOTE")
        XCTAssertEqual(read.note?.by, "Tony")
        XCTAssertEqual(read.note?.at, ISO8601DateFormatter().date(from: "2026-11-10T13:40:00Z"))
        XCTAssertEqual(read.note?.readBy, TicketNoteRead.ReadBy(runID: "run-3", at: ISO8601DateFormatter().date(from: "2026-11-10T14:02:00Z")))
        XCTAssertEqual(read.brief?.at, ISO8601DateFormatter().date(from: "2026-11-10T09:12:00Z"))
        XCTAssertNotNil(read.brief?.walkthrough)
        XCTAssertEqual(read.workspace, TicketWorkspaceRead(path: "/Users/tonypine/symphony-workspaces/symphony/TP-1447"))
        XCTAssertEqual(read.noteMove, TicketMoveRead(allowed: true))
    }

    func testAReadSymphonyHoldsNothingOfDecodesEmptyAndAnythingButAnObjectIsNone() throws {
        let read = try read("details-empty")
        XCTAssertEqual(read, TicketDetailsRead(
            ticket: TicketRecordRead(), noteMove: TicketMoveRead(allowed: false, reason: "No ticket TP-1 in symphony")
        ))
        XCTAssertEqual(TicketDetailsRead.decode(Data("{}".utf8)), TicketDetailsRead())
        XCTAssertEqual(
            TicketDetailsRead.decode(Data(#"{"note":{"text":null},"brief":{},"ticket":{}}"#.utf8)),
            TicketDetailsRead(ticket: TicketRecordRead(), note: TicketNoteRead(text: ""), brief: TicketBriefRead(text: ""))
        )
        XCTAssertNil(TicketDetailsRead.decode(Data("[]".utf8)))
    }

    // MARK: - The Note for the next run panel

    func testANoteARunReadNamesTheRunAndWhenAndSaysLaterRunsStillReadIt() throws {
        let model = try note("details")
        let current = try XCTUnwrap(model.current)
        XCTAssertEqual(current.text, "Keep the agent description folded by default; the brief is what a person reads first.")
        XCTAssertEqual(current.setLine, "Set by Tony today at 13:40")
        XCTAssertEqual(current.readLine, "Read by implementation run 3 at 14:02")
        XCTAssertTrue(current.read)
        XCTAssertEqual(current.confirmation, NotePanelModel.laterRunsLine)
        XCTAssertEqual(
            current.accessibilityLabel,
            "Note for the next run, Keep the agent description folded by default; the brief is what a person reads first., "
                + "Set by Tony today at 13:40, Read by implementation run 3 at 14:02"
        )
        XCTAssertNil(model.refusal)
    }

    func testANoteNoRunReadSaysNotReadYetAndThatTheNextRunReadsIt() throws {
        let current = try XCTUnwrap(try note("details-unread").current)
        XCTAssertEqual(current.setLine, "Set by Tony today at 14:55")
        XCTAssertEqual(current.readLine, "Not read yet")
        XCTAssertFalse(current.read)
        XCTAssertEqual(current.confirmation, "The next run reads this note before it starts.")
    }

    func testNoNoteSaysSoAndATicketSymphonyCannotTakeANoteOnKeepsSaveOffWithItsReason() throws {
        let model = try note("details-empty")
        XCTAssertNil(model.current)
        XCTAssertEqual(model.refusal, "No ticket TP-1 in symphony")
        XCTAssertEqual(model.saveReason("Something"), "No ticket TP-1 in symphony")
        // A refused move without words still says why.
        let unworded = NotePanelModel.build(note: nil, move: TicketMoveRead(allowed: false), runs: [:], reference: reference, calendar: utc)
        XCTAssertEqual(unworded.refusal, "Symphony can't take a note on this ticket now.")
        // A blank note is no note.
        XCTAssertNil(NotePanelModel.build(note: TicketNoteRead(text: "  "), move: nil, runs: [:], reference: reference).current)
    }

    func testSaveNoteIsOffWhileTheFieldIsEmptyOrTheNoteTooLong() throws {
        let model = try note("details-unread")
        XCTAssertEqual(model.saveReason(""), "Write a note first.")
        XCTAssertEqual(model.saveReason(" \n "), "Write a note first.")
        XCTAssertNil(model.saveReason("Look at the dark snapshots."))
        XCTAssertEqual(
            model.saveReason(String(repeating: "a", count: TicketNoteComposer.maxLength + 1)),
            "A note holds at most 4,000 characters; this one has 4,001"
        )
    }

    func testANoteWithoutAuthorOrTimeAndARunTheHistoryDoesNotHoldStillRead() {
        let read = NotePanelModel.build(
            note: TicketNoteRead(text: "Check it.", readBy: TicketNoteRead.ReadBy(runID: "elsewhere")), move: nil, runs: [:],
            reference: reference, calendar: utc
        )
        XCTAssertEqual(read.current?.setLine, "Set")
        XCTAssertEqual(read.current?.readLine, "Read by a run")
    }

    func testAReadOnAnotherDayNamesTheDay() {
        let yesterday = ISO8601DateFormatter().date(from: "2026-11-09T08:05:00Z")!
        let earlier = ISO8601DateFormatter().date(from: "2026-11-06T18:40:00Z")!
        let run = TicketEventsPayload.Run(runID: "r", runKind: "code_review", runNumber: 2)
        let model = NotePanelModel.build(
            note: TicketNoteRead(text: "Check it.", at: earlier, by: "Tony", readBy: .init(runID: "r", at: yesterday)), move: nil,
            runs: ["r": run], reference: reference, calendar: utc
        )
        XCTAssertEqual(model.current?.setLine, "Set by Tony Fri 6 Nov at 18:40")
        XCTAssertEqual(model.current?.readLine, "Read by code review run 2 yesterday at 08:05")
    }

    func testARunKeepsItsAcronymWhenASentenceNamesIt() {
        XCTAssertEqual(NotePanelModel.runName(TicketEventsPayload.Run(runID: "q", runKind: "qa", runNumber: 2)), "QA run 2")
        XCTAssertEqual(NotePanelModel.runName(TicketEventsPayload.Run(runID: "c", runKind: "ci_fix", runNumber: 1)), "CI fix run 1")
        XCTAssertEqual(NotePanelModel.runName(nil), "a run")
    }

    // MARK: - Saving a note

    private final class NoteCalls {
        var sent: [ControlAction] = []
        var reads = 0
    }

    func testSaveNotePostsTheNoteOnTheTicketThenReadsItAgain() async {
        let composer = TicketNoteComposer(identifier: "TP-1447", text: "  Look at the dark snapshots.\n")
        let calls = NoteCalls()
        let written = await composer.submit(identifier: "TP-1447", repoKey: "symphony", send: { action in
            calls.sent.append(action)
            return .done
        }, read: { calls.reads += 1 })
        XCTAssertTrue(written)
        XCTAssertEqual(calls.sent, [.note(repoKey: "symphony", identifier: "TP-1447", text: "Look at the dark snapshots.")])
        XCTAssertEqual(calls.reads, 1)
        XCTAssertEqual(composer.text, "")
        XCTAssertNil(composer.refusal)
    }

    func testSaveNoteWithoutARepositoryPostsNothingAndARefusalKeepsTheText() async {
        let composer = TicketNoteComposer(text: "Keep it.")
        let calls = NoteCalls()
        let send: (ControlAction) async -> ControlResult = { action in
            calls.sent.append(action)
            return .failed("No ticket TP-1 in symphony")
        }
        let none = await composer.submit(identifier: "TP-1", repoKey: nil, send: send, read: { calls.reads += 1 })
        XCTAssertFalse(none)
        XCTAssertEqual(calls.sent, [])
        XCTAssertEqual(composer.identifier, "TP-1")

        let refused = await composer.submit(identifier: "TP-1", repoKey: "symphony", send: send, read: { calls.reads += 1 })
        XCTAssertFalse(refused)
        XCTAssertEqual(calls.sent.count, 1)
        XCTAssertEqual(calls.reads, 0)
        XCTAssertEqual(composer.text, "Keep it.")
        XCTAssertEqual(composer.refusal, "No ticket TP-1 in symphony")
    }

    // MARK: - The Decisions panel

    func testDecisionsReadNewestFirstEachWithItsQuestionAndAnswer() {
        let model = DecisionsPanelModel.build([
            TicketDecision(
                id: "D1", date: "2026-11-09", title: "Keep the facts rail at 340 pt",
                question: "How wide is the rail on a laptop?", answer: "340 pt, as the catalog shows.", scope: "The rail's width is fixed."
            ),
            TicketDecision(id: "D2", date: "2026-11-10", question: "  ", answer: "Fold the agent description by default."),
        ])
        XCTAssertEqual(model.rows.map(\.id), ["D2", "D1"])
        XCTAssertEqual(model.rows[0], DecisionsPanelModel.Row(
            id: "D2", headline: "Fold the agent description by default.", date: "2026-11-10", question: nil,
            answer: "Fold the agent description by default.", scope: nil,
            accessibilityLabel: "Decision D2, Fold the agent description by default., decided 2026-11-10"
        ))
        XCTAssertEqual(model.rows[1].headline, "Keep the facts rail at 340 pt")
        XCTAssertEqual(model.rows[1].question, "How wide is the rail on a laptop?")
        XCTAssertEqual(model.rows[1].answer, "340 pt, as the catalog shows.")
        XCTAssertEqual(model.rows[1].scope, "The rail's width is fixed.")
        XCTAssertEqual(DecisionsPanelModel.build([]).rows, [])
        XCTAssertEqual(DecisionsPanelModel.build([TicketDecision(id: "D3", answer: "Yes.")]).rows[0].accessibilityLabel, "Decision D3, Yes.")
    }

    // MARK: - The Details panel

    func testDetailsSayTheRepoPriorityLabelsWorkspaceModelsLinksAndBrief() throws {
        let pr = TicketPullRequest(number: 870, url: URL(string: "https://github.com/acme/symphony/pull/870"))
        let model = DetailsPanelModel.build(
            try read("details"), runs: try runs(), linearURL: URL(string: "https://linear.app/acme/issue/TP-1447"), pullRequest: pr,
            description: "  ## Goal\nThree more panels.  ", reference: reference, calendar: utc
        )
        XCTAssertEqual(model.repo, "symphony")
        XCTAssertEqual(model.priority, "Urgent")
        XCTAssertEqual(model.labels, ["skip-update-hold", "qa:fixture"])
        XCTAssertEqual(model.workspace, "/Users/tonypine/symphony-workspaces/symphony/TP-1447")
        XCTAssertNil(model.workspaceHost)
        XCTAssertEqual(model.models, [
            DetailsPanelModel.RunModel(id: "run-1", run: "Implementation run 1", model: "claude-opus-5-5 · high effort"),
            DetailsPanelModel.RunModel(id: "run-2", run: "Code Review run 1", model: "claude-sonnet-5-5"),
            DetailsPanelModel.RunModel(id: "run-3", run: "Implementation run 3", model: "claude-opus-5-5 · high effort"),
        ])
        XCTAssertEqual(model.modelsSummary, "3 runs · claude-opus-5-5, claude-sonnet-5-5")
        XCTAssertEqual(model.links.map(\.title), ["Ticket in Linear", "PR #870 on GitHub"])
        XCTAssertEqual(model.links.map(\.id), ["Ticket in Linear", "PR #870 on GitHub"])
        XCTAssertEqual(model.brief?.written, "Written today at 09:12")
        XCTAssertNotNil(model.brief?.walkthrough)
        XCTAssertEqual(model.agentDescription, "## Goal\nThree more panels.")
    }

    func testDetailsOfATicketSymphonyHoldsNothingOfLeaveTheUnknownOut() throws {
        let model = DetailsPanelModel.build(
            try read("details-empty"), runs: [:], linearURL: nil, pullRequest: TicketPullRequest(number: 1), description: " ",
            reference: reference, calendar: utc
        )
        XCTAssertNil(model.repo)
        XCTAssertNil(model.priority)
        XCTAssertEqual(model.labels, [])
        XCTAssertNil(model.workspace)
        XCTAssertEqual(model.models, [])
        XCTAssertNil(model.modelsSummary)
        XCTAssertEqual(model.links, [])
        XCTAssertNil(model.brief)
        XCTAssertNil(model.agentDescription)
        XCTAssertEqual(DetailsPanelModel.build(nil, runs: [:], linearURL: nil, pullRequest: nil, description: nil, reference: reference).repo, nil)
    }

    func testEachPriorityHasItsWordAndAWorkspaceElsewhereNamesItsMachine() {
        XCTAssertEqual([0, 1, 2, 3, 4, 9].map(DetailsPanelModel.priorityWord), ["No priority", "Urgent", "High", "Medium", "Low", nil])
        let read = TicketDetailsRead(workspace: TicketWorkspaceRead(path: "/srv/w/TP-1", host: "builder-2"))
        XCTAssertEqual(DetailsPanelModel.build(read, runs: [:], linearURL: nil, pullRequest: nil, description: nil, reference: reference).workspaceHost, "builder-2")
        let blank = TicketDetailsRead(brief: TicketBriefRead(text: " ", walkthrough: "Steps"))
        XCTAssertNil(DetailsPanelModel.build(blank, runs: [:], linearURL: nil, pullRequest: nil, description: nil, reference: reference).brief)
        let undated = TicketDetailsRead(brief: TicketBriefRead(text: "What it does.", walkthrough: " "))
        let brief = DetailsPanelModel.build(undated, runs: [:], linearURL: nil, pullRequest: nil, description: nil, reference: reference).brief
        XCTAssertEqual(brief, DetailsPanelModel.Brief(text: "What it does.", walkthrough: nil, written: nil))
    }

    func testOneRunsModelIsSummedUpAsOneRun() {
        let runs = ["a": TicketEventsPayload.Run(runID: "a", runKind: "implementation", runNumber: 1, model: "gpt-6", effort: " ")]
        let models = DetailsPanelModel.runModels(runs)
        XCTAssertEqual(models.map(\.model), ["gpt-6"])
        XCTAssertEqual(DetailsPanelModel.modelsSummary(models), "1 run · gpt-6")
    }
}
