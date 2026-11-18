import Foundation
@testable import SymphonyBarCore
import XCTest

/// A run followable on the ticket page while it walks no steps (a QA or Code Review run): its newest lines under the
/// run, its whole session in the reader once it ended, and the screenshots it records inside its group.
final class RunVisibilityTests: XCTestCase {
    private let reference = ISO8601DateFormatter().date(from: "2026-11-18T10:30:00Z")!

    private func event(
        _ id: String, _ type: String, _ at: String, _ payload: TicketEventsPayload.Payload = .init(),
        artifacts: [TicketEventsPayload.Artifact] = []
    ) -> TicketEventsPayload.Event {
        TicketEventsPayload.Event(
            id: id, seq: nil, at: at, type: type, runID: "r", parent: nil, actor: nil, summary: nil, payload: payload, artifacts: artifacts
        )
    }

    private func shot(_ id: String) -> TicketEventsPayload.Artifact {
        TicketEventsPayload.Artifact(id: id, kind: "screenshot", label: "Shot \(id)", mime: "image/png", url: "/api/v1/artifacts/\(id)")
    }

    private func run(status: String) -> TicketEventsPayload.Run {
        TicketEventsPayload.Run(runID: "r", runKind: "qa", runNumber: 1, status: status, startedAt: "2026-11-18T10:00:00Z")
    }

    // MARK: - Lines of a run on no step

    func testARunOnNoStepHasTheRunNowsNewestLinesUnderTheRun() {
        let lines = [TranscriptLine(kind: .say, text: "Opening the app."), TranscriptLine(kind: .tool, text: "Bash")]
        let runNow = RunNow(currentStep: nil, lines: lines)
        let live = RunGroupModel.group(run(status: "running"), events: [event("1", "run.started", "2026-11-18T10:00:00Z")], runNow: runNow, reference: reference)

        XCTAssertTrue(live.steps.isEmpty)
        XCTAssertEqual(live.liveLines, lines)
        XCTAssertTrue(SessionReader.canRead(live))

        // On a step, the lines are the step's, not the run's.
        let onStep = RunNow(currentStep: .init(id: "walk", title: "Walk", startedAt: "2026-11-18T10:01:00Z"), lines: lines)
        let stepped = RunGroupModel.group(run(status: "running"), events: [], runNow: onStep, reference: reference)
        XCTAssertTrue(stepped.liveLines.isEmpty)
        XCTAssertEqual(stepped.steps.first?.liveLines, lines)

        // An ended run takes no live lines.
        let ended = RunGroupModel.groups(history(status: "ended"), runNow: runNow, reference: reference)[0]
        XCTAssertTrue(ended.liveLines.isEmpty)
    }

    private func history(status: String) -> TicketEventsPayload {
        var history = TicketEventsPayload()
        let page = #"{"timeline":[{"kind":"run","run_id":"r","run_kind":"qa","run_number":1,"status":"\#(status)","started_at":"2026-11-18T10:00:00Z","events":[]}]}"#
        history.merge(TicketEventsPayload.decode(Data(page.utf8))!)
        return history
    }

    // MARK: - The reader of a run that walks no steps

    func testAnEndedRunReadsItsWholeSessionAsLines() {
        let transcript = TicketEventsPayload.Artifact(id: "abc", kind: "transcript", label: "session.jsonl", url: "/api/v1/artifacts/abc")
        let ended = RunGroupModel.group(
            run(status: "ended"), events: [event("1", "run.ended", "2026-11-18T10:20:00Z", .init(exit: "success"), artifacts: [transcript])],
            reference: reference
        )
        XCTAssertEqual(ended.transcript, TicketOutput(id: "abc/lines", label: "session.jsonl", path: "api/v1/artifacts/abc/lines", available: true))
        XCTAssertTrue(SessionReader.canRead(ended))

        let said = TranscriptLine(kind: .say, text: "Checked the header.", at: "2026-11-18T10:05:00Z")
        let reader = SessionReader.build(identifier: "TP-1496", run: ended) { $0.id == "abc/lines" ? .loaded([said]) : .failed }
        XCTAssertTrue(reader.sections.isEmpty)
        XCTAssertEqual(reader.lines.map(\.line), [said])
        XCTAssertEqual(SessionReader.build(identifier: "TP-1496", run: ended) { _ in .loading }.session, .loading)
        XCTAssertEqual(SessionReader.build(identifier: "TP-1496", run: ended) { _ in .unavailable }.session, .unavailable)
        XCTAssertEqual(SessionReader.build(identifier: "TP-1496", run: ended) { _ in .failed }.session, .failed)
        XCTAssertEqual(SessionReader.build(identifier: "TP-1496", run: ended) { _ in .loaded([]) }.session, .empty)
    }

    func testTheRunNowsLinesAreItsSessionAndARunWithNothingHasNone() {
        var live = RunGroupModel(id: "r", title: "QA run 1", state: .running, word: "Running")
        XCTAssertFalse(SessionReader.canRead(live))
        XCTAssertNil(SessionReader.build(identifier: "T-1", run: live) { _ in .loading }.session)

        let line = TranscriptLine(kind: .say, text: "Walking step 2.")
        live.liveLines = [line]
        let reader = SessionReader.build(identifier: "T-1", run: live) { _ in .loading }
        XCTAssertEqual(reader.lines.map(\.line), [line])
        XCTAssertEqual(reader.lines.first?.id, "r||say|Walking step 2.")

        // A run with steps reads them, never a session of its own.
        let stepped = RunGroupModel(
            id: "s", title: "Implementation run 1", state: .passed, word: "Passed",
            steps: [RunStep(id: "code", stepID: "code", title: "Write the code", state: .done)]
        )
        XCTAssertNil(SessionReader.build(identifier: "T-1", run: stepped) { _ in .loading }.session)
    }

    func testASessionWithoutLinesSaysWhy() {
        XCTAssertNil(SessionReader.sessionNote(.lines([])))
        XCTAssertEqual(SessionReader.sessionNote(.loading), "Reading the session…")
        XCTAssertEqual(SessionReader.sessionNote(.unavailable), "Symphony no longer keeps this session.")
        XCTAssertEqual(SessionReader.sessionNote(.failed), "Couldn't read this session. Close the window and open it again to try again.")
        XCTAssertEqual(SessionReader.sessionNote(.empty), "The agent said nothing in this run.")
    }

    // MARK: - Screenshots inside the run

    func testScreenshotsSitUnderTheStepTheyWereRecordedInElseUnderTheRun() {
        let finding = TicketEventsPayload.Payload(description: "The row is cut.")
        let events = [
            event("1", "run.started", "2026-11-18T10:00:00Z"),
            event("2", "step.started", "2026-11-18T10:00:00Z", .init(stepID: "walk", title: "Walk the change")),
            event("3", "evidence", "2026-11-18T10:00:30Z", artifacts: [shot("a"), shot("b")]),
            event("4", "finding.recorded", "2026-11-18T10:00:40Z", finding, artifacts: [shot("f")]),
            event("5", "step.completed", "2026-11-18T10:01:00Z", .init(outcome: "passed", stepID: "walk")),
            event("6", "evidence", "2026-11-18T10:02:00Z", artifacts: [shot("c")]),
            event("7", "evidence", "2026-11-18T10:02:10Z", artifacts: [shot("c")]),
            event("8", "step.started", "2026-11-18T10:05:00Z", .init(stepID: "review", title: "Review")),
            event("9", "evidence", "2026-11-18T10:06:00Z", artifacts: [shot("d")]),
            event("10", "evidence", "not a time", artifacts: [shot("e")]),
        ]
        let group = RunGroupModel.group(run(status: "running"), events: events, runNow: RunNow(currentStep: nil, lines: []), reference: reference)

        XCTAssertEqual(group.steps.map(\.id), ["walk", "review"])
        XCTAssertEqual(group.steps[0].screenshots.map(\.id), ["a", "b"])
        // The step the run is on holds what it records now.
        XCTAssertEqual(group.steps[1].screenshots.map(\.id), ["d"])
        // Between steps, or with no time, under the run; a screenshot recorded twice shows once; a finding's are its card's.
        XCTAssertEqual(group.screenshots.map(\.id), ["c", "e"])
    }

    func testARunThatWalksNoStepsHoldsItsScreenshotsItself() {
        let events = [event("1", "run.started", "2026-11-18T10:00:00Z"), event("2", "evidence", "2026-11-18T10:03:00Z", artifacts: [shot("a")])]
        let group = RunGroupModel.group(run(status: "running"), events: events, reference: reference)
        XCTAssertTrue(group.steps.isEmpty)
        XCTAssertEqual(group.screenshots.map(\.label), ["Shot a"])
        XCTAssertTrue(RunGroupModel.group(run(status: "running"), events: [events[0]], reference: reference).screenshots.isEmpty)
    }
}
