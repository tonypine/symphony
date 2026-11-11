import Foundation
@testable import SymphonyBarCore
import XCTest

/// The session reader (TP-1452): one run's whole session, step by step, and the timeline's line when no run works.
final class SessionReaderTests: XCTestCase {
    private let reference = ISO8601DateFormatter().date(from: "2026-10-08T10:27:00Z")!

    private func output(_ id: String, available: Bool = true) -> TicketOutput {
        TicketOutput(id: id, label: "Transcript", path: "api/v1/artifacts/\(id)", available: available)
    }

    private func run(_ steps: [RunStep], state: RunGroupModel.State = .failed) -> RunGroupModel {
        RunGroupModel(id: "run-1", title: "Implementation run 1", state: state, word: "Failed", steps: steps)
    }

    // MARK: - The reader

    func testEachStepReadsItsTranscriptAndTheRunNowsStepItsNewestLines() {
        let said = TranscriptLine(kind: .say, text: "Reading the ticket.", at: "2026-10-08T09:02:30Z")
        let long = TranscriptLine(kind: .result, text: String(repeating: "x", count: SessionReader.shortLength + 1), failed: true)
        let live = TranscriptLine(kind: .tool, text: "Bash: mix test")
        let steps = [
            RunStep(id: "code", stepID: "code", title: "Write the code", state: .done, transcript: output("a")),
            RunStep(id: "tests", stepID: "tests", title: "Tests", state: .done, transcript: output("b")),
            RunStep(id: "checks", stepID: "checks", title: "Checks", state: .done, transcript: output("c")),
            RunStep(id: "gone", stepID: "gone", title: "Gone", state: .done, transcript: output("d", available: false)),
            RunStep(id: "none", stepID: "none", title: "No transcript", state: .skipped),
            RunStep(id: "code#2", stepID: "code", title: "Write the code", state: .current, liveLines: [live]),
        ]
        let lines: (TicketOutput) -> StepTranscripts.Lines = { transcript in
            switch transcript.id {
            case "a": .loaded([said, long])
            case "b": .loading
            case "c": .failed
            default: .unavailable
            }
        }
        let reader = SessionReader.build(identifier: "TP-1452", run: run(steps, state: .running), lines: lines)

        XCTAssertEqual(reader.windowTitle, "TP-1452 · Implementation run 1")
        XCTAssertEqual(reader.sections.map(\.id), ["code", "tests", "checks", "gone", "none", "code#2"])
        guard case let .lines(first) = reader.sections[0].content else { return XCTFail("The code step reads its lines") }
        XCTAssertEqual(first.map(\.line), [said, long])
        XCTAssertEqual(first.map(\.expands), [false, true])
        XCTAssertEqual(reader.sections[1].content, .loading)
        XCTAssertEqual(reader.sections[2].content, .failed)
        XCTAssertEqual(reader.sections[3].content, .unavailable)
        XCTAssertEqual(reader.sections[4].content, .noTranscript)
        XCTAssertEqual(reader.sections[5].content, .lines([SessionReader.Line(id: "code#2||tool|Bash: mix test", line: live)]))
        // Every line, top to bottom, across the steps.
        XCTAssertEqual(reader.lines.map(\.line), [said, long, live])
    }

    func testAlikeLinesKeepTheirOwnKeysAndAMultiLineOneExpands() {
        let line = TranscriptLine(kind: .say, text: "Same.")
        let step = RunStep(id: "code", stepID: "code", title: "Code", state: .current)
        guard case let .lines(lines) = SessionReader.keyed([line, line], step: step) else { return XCTFail("Two lines") }
        XCTAssertEqual(lines.map(\.id), ["code||say|Same.", "code||say|Same.#2"])
        XCTAssertEqual(SessionReader.keyed([], step: step), .empty)
        XCTAssertTrue(SessionReader.Line(id: "x", line: TranscriptLine(kind: .say, text: "one\ntwo")).expands)
        XCTAssertFalse(SessionReader.Line(id: "x", line: TranscriptLine(kind: .say, text: "short")).expands)
    }

    func testTheRunNowsStepWithNoLineYetIsEmptyAndOneThatCompletedReadsItsTranscript() {
        let started = RunStep(id: "code", stepID: "code", title: "Code", state: .current)
        let reader = SessionReader.build(identifier: "T-1", run: run([started], state: .running), lines: { _ in .loading })
        XCTAssertEqual(reader.sections.first?.content, .empty)
        XCTAssertEqual(SessionReader.note(.empty, live: true), "The agent hasn't said anything in this step yet.")

        // A live step that has a transcript and no live lines reads the transcript.
        let kept = RunStep(id: "code", stepID: "code", title: "Code", state: .current, transcript: output("a"))
        let read = SessionReader.build(identifier: "T-1", run: run([kept], state: .running), lines: { _ in .loaded([]) })
        XCTAssertEqual(read.sections.first?.content, .empty)
        XCTAssertTrue(read.lines.isEmpty)
    }

    func testWhatTheReaderSaysForAStepWithoutLines() {
        XCTAssertNil(SessionReader.note(.lines([]), live: false))
        XCTAssertEqual(SessionReader.note(.loading, live: false), "Reading what happened in this step…")
        XCTAssertEqual(SessionReader.note(.unavailable, live: false), "Symphony no longer keeps what happened in this step.")
        XCTAssertEqual(
            SessionReader.note(.failed, live: false),
            "Couldn't read what happened in this step. Close the window and open it again to try again."
        )
        XCTAssertEqual(SessionReader.note(.empty, live: false), "The agent said nothing in this step.")
        XCTAssertEqual(SessionReader.note(.noTranscript, live: false), "Symphony kept no lines for this step.")
        XCTAssertEqual(SessionReader.expandLabel(expanded: false), "Show all")
        XCTAssertEqual(SessionReader.expandLabel(expanded: true), "Show less")
        XCTAssertEqual(SessionReader.menuTitle, "Read the whole session")
    }

    func testARunCanBeReadOnceAStepHasSomethingInIt() {
        XCTAssertFalse(SessionReader.canRead(run([])))
        XCTAssertFalse(SessionReader.canRead(run([RunStep(id: "s", stepID: "s", title: "S", state: .skipped)])))
        XCTAssertTrue(SessionReader.canRead(run([RunStep(id: "s", stepID: "s", title: "S", state: .done, transcript: output("a"))])))
        XCTAssertTrue(SessionReader.canRead(run([RunStep(id: "s", stepID: "s", title: "S", state: .current)], state: .running)))
        XCTAssertTrue(SessionReader.build(identifier: "T-1", run: run([]), lines: { _ in .loading }).sections.isEmpty)
    }

    // MARK: - The line when no run works

    func testTheNoRunLineSaysWhyInTheSituationsWords() throws {
        XCTAssertNil(TimelineIdleLine(nil, reference: reference))

        let you = try XCTUnwrap(TimelineIdleLine(
            Situation(kind: .you, cause: "Run 2 asked how the times should read.", next: "Answer below."), reference: reference
        ))
        XCTAssertEqual(you.kind, .you)
        XCTAssertEqual(you.lead, "No run now")
        XCTAssertEqual(you.word, "Waiting on you")
        XCTAssertEqual(you.detail, "Run 2 asked how the times should read. Answer below.")
        XCTAssertEqual(you.accessibilityLabel, "No run now. Waiting on you: Run 2 asked how the times should read. Answer below.")

        let shipped = try XCTUnwrap(TimelineIdleLine(Situation(kind: .done, word: "Shipped", cause: ""), reference: reference))
        XCTAssertNil(shipped.detail)
        XCTAssertEqual(shipped.accessibilityLabel, "No run now. Shipped")

        let slot = try XCTUnwrap(TimelineIdleLine(Situation(kind: .slot, cause: "Every slot is taken.", next: ""), reference: reference))
        XCTAssertEqual(slot.detail, "Every slot is taken.")
    }
}
