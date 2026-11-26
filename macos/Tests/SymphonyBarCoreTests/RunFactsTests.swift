import Foundation
import XCTest
@testable import SymphonyBarCore

/// The facts a run recorded, drawn in its conversation where it recorded them (TP-1698): read from the ticket's events
/// on the facts fixture (`Fixtures/director-app/ticket-facts`, written by the Elixir controller test from Symphony's own
/// events) and the review fixture (`ticket-review-conversation`), never from a line's text.
@MainActor
final class RunFactsTests: XCTestCase {
    private static let utc = TimeZone(identifier: "UTC")!
    private let reference = TicketPage.date("2026-10-31T13:00:00Z")!
    private let picture = "7763409689b96f805ef476477c10d809e7c5e3b42df5f4ceb05f69833bb1582d"

    private static func api(_ fixture: String) -> URL {
        TicketEventsTests.director(fixture).appendingPathComponent("api/v1")
    }

    private func runs(_ fixture: String) throws -> [RunGroupModel] {
        let api = Self.api(fixture)
        let history = try XCTUnwrap(TicketEventsPayload.decode(Data(contentsOf: api.appendingPathComponent("repos/web-shop/tickets/SHOP-410/events.json"))))
        return RunGroupModel.groups(history, reference: reference)
    }

    private func run(_ fixture: String, _ title: String) throws -> RunGroupModel {
        try XCTUnwrap(runs(fixture).first { $0.title == title }, "the fixture holds \(title)")
    }

    /// A transcript's lines, read from the fixture at the address the app reads them from: a step's as `<path>.txt`.
    private func lines(_ fixture: String, _ output: TicketOutput?) throws -> [TranscriptLine] {
        let path = try XCTUnwrap(output?.path).replacingOccurrences(of: "api/v1/", with: "")
        return TranscriptLine.lines(try Data(contentsOf: Self.api(fixture).appendingPathComponent(path + ".txt")))
    }

    private func entries(_ lines: [TranscriptLine], _ facts: [RunFact]) -> [ConversationEntry] {
        RunConversation.entries(lines, facts: facts, timeZone: Self.utc)
    }

    // MARK: - c1: a review's verdict

    func testACodeReviewsVerdictIsAChipWithItsFindingsFilesAndLinesWhereItWasRecorded() throws {
        let review = try run("ticket-review-conversation", "Code Review run 1")
        XCTAssertTrue(review.steps.isEmpty)
        let session = try lines("ticket-review-conversation", review.transcript)

        let drawn = entries(session, review.facts)
        // The verdict was recorded after the six actions (the last at 12:51:20) and before the review's note (12:51:26).
        XCTAssertEqual(drawn.map(\.kind), [.actions, .fact, .note])
        XCTAssertEqual(drawn[0].actions.count, 6)
        guard case let .verdict(verdict) = drawn[1].fact?.kind else { return XCTFail("the verdict is not drawn") }
        XCTAssertEqual(verdict.word, "Request changes")
        XCTAssertEqual(verdict.state, .sentBack)
        XCTAssertEqual(verdict.findings.map(\.fileName), ["DoneRow.swift", "DesignTokens.swift"])
        XCTAssertEqual(verdict.findings.map(\.linesText), ["70–79", "1883–1885"])
        XCTAssertEqual(drawn[1].minute, "12:51")
    }

    func testAVerdictsWordAndStateComeFromItsKindAndOutcome() {
        XCTAssertEqual(RunFact.verdict(kind: "code_review", outcome: "rework", findings: [])?.word, "Request changes")
        XCTAssertEqual(RunFact.verdict(kind: "qa", outcome: "block", findings: [])?.state, .blocked)
        XCTAssertEqual(RunFact.verdict(kind: "code_review", outcome: "approve", findings: [])?.word, "Approved")
        XCTAssertEqual(RunFact.verdict(kind: "qa", outcome: "pass", findings: [])?.word, "Passed")
        XCTAssertEqual(RunFact.verdict(kind: "qa", outcome: "fail", findings: [])?.state, .failed)
        XCTAssertEqual(RunFact.verdict(kind: "qa", outcome: "plan_mismatch", findings: [])?.word, "Plan mismatch")
        XCTAssertNil(RunFact.verdict(kind: "qa", outcome: " ", findings: []))
        XCTAssertNil(RunFact.verdict(kind: "qa", outcome: nil, findings: []))
    }

    // MARK: - c2, c3, c5: a QA walk's answers, evidence and pictures

    func testAQAWalksStepAnswersAreDrawnWhereRecordedFromTheirAnswersNotTheirCommands() throws {
        let qa = try run("ticket-facts", "QA run 1")
        XCTAssertEqual(qa.steps.map(\.stepID), ["check_1", "walk_2_3"])
        let walk = qa.steps[1]
        XCTAssertTrue(walk.canUnfold)

        let drawn = entries(try lines("ticket-facts", walk.transcript), walk.facts)
        // The same crop failing twice is one failure row; the blocked evidence and its answer (10:48) sit before the note
        // written after them (10:48:30); the walk's own answer (10:50) comes last.
        XCTAssertEqual(drawn.map(\.kind), [.note, .failure, .fact, .fact, .note, .fact])
        XCTAssertEqual(drawn[0].actions.count, 1)
        XCTAssertEqual(drawn[1].repeats, 2)
        guard case let .evidence(counts, _, _) = drawn[2].fact?.kind else { return XCTFail("the blocked evidence is not drawn") }
        XCTAssertEqual(counts, [RunFact.EvidenceCount(step: "3", count: 1)])
        XCTAssertEqual(drawn[3].fact?.kind, .answer([RunFact.Mark(title: "Step 3", state: .blocked)], measures: []))
        guard case let .answer(marks, measures) = drawn[5].fact?.kind else { return XCTFail("the walk's answer is not drawn") }
        XCTAssertEqual(marks, [
            RunFact.Mark(title: "Step 2", state: .done),
            RunFact.Mark(title: "Step 3", state: .failed),
        ])
        XCTAssertEqual(measures.map(\.text), ["Menu label width 0 pt, expected 80 pt"])

        // The blocked evidence's answer: the struck circle's state, in the idle grey.
        let blocked = try XCTUnwrap(walk.facts.first { $0.id.hasPrefix("fx-19") && $0.id.hasSuffix("answer") })
        guard case let .answer(blockedMarks, _) = blocked.kind else { return XCTFail("the blocked answer is not a fact") }
        XCTAssertEqual(blockedMarks, [RunFact.Mark(title: "Step 3", state: .blocked)])
        XCTAssertEqual(blockedMarks[0].word, "Blocked")
        XCTAssertEqual(blockedMarks[0].state.symbol, "circle.slash")
        XCTAssertEqual(blockedMarks[0].state.status, .idle)
    }

    func testAQAChecksEvidenceCountsMeasuresAndRealPicturesAreDrawnWhereRecorded() throws {
        let qa = try run("ticket-facts", "QA run 1")
        let check = qa.steps[0]
        let drawn = entries(try lines("ticket-facts", check.transcript), check.facts)

        // The picture and its answer (10:44) after the screenshot's action, folded under its note, and before the note at
        // 10:44:30; the measures (10:45) after the measuring action; the check's answer (10:46) last.
        XCTAssertEqual(drawn.map(\.kind), [.note, .failure, .note, .fact, .fact, .note, .fact, .note, .fact])
        XCTAssertEqual(drawn[2].actions.count, 2)

        guard case let .evidence(counts, _, pictures) = drawn[3].fact?.kind else { return XCTFail("the picture is not drawn") }
        XCTAssertEqual(counts, [RunFact.EvidenceCount(step: "1", count: 1)])
        XCTAssertEqual(counts[0].title, "Step 1 evidence")
        // The real picture, at its artifact's address, named.
        XCTAssertEqual(pictures.map(\.screenshot.path), ["api/v1/artifacts/\(picture)"])
        XCTAssertEqual(pictures.map(\.screenshot.label), ["Settings after the relaunch"])
        let bytes = try Data(contentsOf: Self.api("ticket-facts").appendingPathComponent("artifacts/\(picture).png"))
        XCTAssertEqual(Array(bytes.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
        // A picture drawn in the conversation is not drawn again beside it.
        XCTAssertEqual(check.facts.pictureIDs, [picture])
        XCTAssertEqual(check.screenshots.map(\.id), [picture])

        XCTAssertEqual(drawn[4].fact?.kind, .answer([RunFact.Mark(title: "Step 1", state: .done)], measures: []))

        guard case let .evidence(moreCounts, measures, morePictures) = drawn[6].fact?.kind else { return XCTFail("the measures are not drawn") }
        XCTAssertEqual(moreCounts, [RunFact.EvidenceCount(step: nil, count: 1)])
        XCTAssertEqual(moreCounts[0].title, "Evidence")
        XCTAssertEqual(measures.map(\.text), ["Window width 1440 pt", "Filter restored after launch 0.42 s"])
        XCTAssertEqual(measures.map(\.valueText), ["1440 pt", "0.42 s"])
        XCTAssertEqual(morePictures, [])

        guard case let .answer(marks, answerMeasures) = drawn[8].fact?.kind else { return XCTFail("the check's answer is not drawn") }
        XCTAssertEqual(marks, [RunFact.Mark(title: "The filter survives a relaunch", state: .done)])
        XCTAssertEqual(answerMeasures.map(\.text), ["Rows shown 3 rows"])
    }

    func testEvidenceSideBySideIsOneEntryWithItsCountsByStep() {
        let at = TicketPage.date("2026-10-18T10:44:00Z")
        let shot = TicketPicture(caption: nil, step: "6", screenshot: TicketScreenshot(id: "a", label: "home-rest", path: "api/v1/artifacts/a", available: true))
        let facts = [
            RunFact(id: "e1", date: at, kind: .evidence(counts: [.init(step: "6", count: 1)], measures: [], pictures: [shot])),
            RunFact(id: "e2", date: at, kind: .evidence(counts: [.init(step: "6", count: 1)], measures: [], pictures: [])),
            RunFact(id: "e3", date: at, kind: .evidence(counts: [.init(step: "12", count: 1)], measures: [TicketMeasure(name: "Width", value: 2.5, unit: "")], pictures: [])),
            RunFact(id: "a1", date: at, kind: .answer([RunFact.Mark(title: "Step 6", state: .blocked)], measures: [])),
            RunFact(id: "a2", date: at, kind: .answer([RunFact.Mark(title: "Step 12", state: .blocked)], measures: [])),
            RunFact(id: "p1", date: nil, kind: .provedChecks(test: "a_test.exs", checkIDs: ["c1"])),
            RunFact(id: "p2", date: nil, kind: .provedChecks(test: "a_test.exs", checkIDs: ["c2", "c1"])),
            RunFact(id: "p3", date: nil, kind: .provedChecks(test: "b_test.exs", checkIDs: ["c3"])),
        ]
        let drawn = RunConversation.entries([], facts: facts, live: true, timeZone: Self.utc)
        XCTAssertEqual(drawn.count, 4)
        XCTAssertEqual(drawn[0].fact?.kind, .evidence(
            counts: [.init(step: "6", count: 2), .init(step: "12", count: 1)], measures: [TicketMeasure(name: "Width", value: 2.5, unit: "")], pictures: [shot]
        ))
        XCTAssertEqual(drawn[0].minute, "10:44")
        XCTAssertEqual(drawn[0].fact?.pictures, [shot])
        XCTAssertEqual(drawn[1].fact?.kind, .answer([RunFact.Mark(title: "Step 6", state: .blocked), RunFact.Mark(title: "Step 12", state: .blocked)], measures: []))
        XCTAssertEqual(drawn[1].fact?.pictures, [])
        // The checks one test proves are listed under it; another test's under it.
        XCTAssertEqual(drawn[2].fact?.kind, .provedChecks(test: "a_test.exs", checkIDs: ["c1", "c2"]))
        XCTAssertEqual(drawn[3].fact?.kind, .provedChecks(test: "b_test.exs", checkIDs: ["c3"]))
        XCTAssertNil(drawn[3].minute)
        XCTAssertEqual(drawn.map(\.working), [false, false, false, true])
        XCTAssertEqual(TicketMeasure(name: "Width", value: 2.5, unit: "").valueText, "2.5")
        XCTAssertNil(TicketMeasure(name: "Width", value: 2.5, unit: "").expectedText)
        XCTAssertEqual(TicketMeasure(name: "Gap", value: 4, unit: "", expected: 8).text, "Gap 4, expected 8")
    }

    // MARK: - c4, c6: a coding run's test result, proved check, files and commits

    func testACodingRunsTestResultProvedCheckFilesAndCommitAreItsFactsInOrder() throws {
        let impl = try run("ticket-facts", "Implementation run 1")
        XCTAssertTrue(impl.steps.isEmpty)
        XCTAssertNil(impl.transcript)

        // With no lines, the facts stand alone, oldest first: the tests (10:18), the check (10:19), the changes (10:20).
        let drawn = entries([], impl.facts)
        XCTAssertEqual(drawn.map(\.kind), [.fact, .fact, .fact])
        guard case let .testResult(result) = drawn[0].fact?.kind else { return XCTFail("the test result is not drawn") }
        XCTAssertEqual(result.text, "41 passed, 1 failed, 2 skipped · 1 min 35 s")
        XCTAssertTrue(result.isRed)
        XCTAssertEqual(drawn[1].fact?.kind, .provedChecks(test: "test/web_shop/filter_test.exs: keeps the filter after a relaunch", checkIDs: ["c1"]))
        guard case let .changes(changes) = drawn[2].fact?.kind else { return XCTFail("the changes are not drawn") }
        XCTAssertEqual(changes.files.map { ActionGist.fileName($0.path) }, ["filter.ex", "settings.ex", "tab.ex"])
        XCTAssertEqual(changes.commits.map(\.shortSHA), ["c0ffee1", "bbb2222"])
        XCTAssertEqual(changes.commits.first?.subject, "Keep the filter in settings")
        XCTAssertEqual(changes.commitCount, 3)
    }

    func testATestResultReadsItsCountsAndTime() {
        XCTAssertEqual(TicketTestResult(passed: 12, failed: 0).text, "12 passed, 0 failed")
        XCTAssertFalse(TicketTestResult(passed: 12, failed: 0).isRed)
        XCTAssertEqual(TicketTestResult(passed: 1, failed: 0, skipped: 0, durationMs: 400).text, "1 passed, 0 failed · 400 ms")
        XCTAssertEqual(TicketTestResult(passed: 1, failed: 0, durationMs: 41_000).text, "1 passed, 0 failed · 41 s")
        XCTAssertEqual(TicketTestResult(passed: 1, failed: 0, durationMs: 120_000).text, "1 passed, 0 failed · 2 min")
        XCTAssertEqual(ReviewFinding(file: "a/b.swift", lineRange: .init(start: 9, end: 9)).linesText, "9")
        XCTAssertNil(ReviewFinding(summary: "x").fileName)
    }

    // MARK: - c7: no fact out of command text

    func testARunWhoseEventsCarryNoFactsDrawsNoFactFromItsCommands() throws {
        // A session full of what the prototype once read: a commit, a test run's output, a verdict call, written files.
        let session: [TranscriptLine] = [
            TranscriptLine(kind: .tool, text: "Bash: git commit -m 'Keep the filter'", at: "2026-10-18T10:01:00Z", tool: "Bash"),
            TranscriptLine(kind: .result, text: "[auto/TP-1 c0ffee1] Keep the filter\n 2 files changed", at: "2026-10-18T10:01:01Z"),
            TranscriptLine(kind: .tool, text: "Bash: swift test", at: "2026-10-18T10:02:00Z", tool: "Bash"),
            TranscriptLine(kind: .result, text: "Executed 12 tests, with 1 failure (0 unexpected)", at: "2026-10-18T10:02:40Z", failed: true),
            TranscriptLine(kind: .tool, text: #"review_verdict: {"verdict": "request_changes"}"#, at: "2026-10-18T10:03:00Z", tool: "review_verdict"),
            TranscriptLine(kind: .result, text: #"{"recorded": true}"#, at: "2026-10-18T10:03:01Z"),
            TranscriptLine(kind: .say, text: "Step 3: **pass**. Evidence recorded.", at: "2026-10-18T10:04:00Z"),
        ]
        let events = [
            TicketEventsPayload.Event(
                id: "n1", seq: 1, at: "2026-10-18T10:03:30Z", type: "note", runID: "r", parent: nil, actor: nil, summary: nil,
                payload: TicketEventsPayload.Payload(text: "Committed and ran the tests"), artifacts: []
            ),
            TicketEventsPayload.Event(
                id: "s1", seq: 2, at: "2026-10-18T10:04:30Z", type: "step.completed", runID: "r", parent: nil, actor: nil, summary: nil,
                payload: TicketEventsPayload.Payload(outcome: "passed", stepID: "code"), artifacts: []
            ),
        ]
        let facts = events.flatMap(RunFact.facts)
        XCTAssertEqual(facts, [])
        let drawn = entries(session, facts)
        XCTAssertFalse(drawn.contains { $0.kind == .fact })
        XCTAssertEqual(drawn.map(\.kind), [.actions, .failure, .actions, .note])
    }

    func testAVerdictWithNoOutcomeAndAStepWithNoJudgementGiveNoMark() throws {
        let verdict = TicketEventsPayload.Event(
            id: "v", seq: 1, at: nil, type: "verdict.recorded", runID: "r", parent: nil, actor: nil, summary: nil,
            payload: TicketEventsPayload.Payload(kind: "qa"), artifacts: []
        )
        XCTAssertEqual(RunFact.facts(verdict), [])
        XCTAssertEqual(RunFact.marks(StepAnswer(), title: nil), [])
        // A result whose status is not a judgement reads done, with its word.
        let odd = StepAnswer(result: StepAnswer.Result(status: "plan_mismatch", expected: nil, actual: nil), results: [])
        XCTAssertEqual(RunFact.marks(odd, title: " "), [RunFact.Mark(title: "Answer", state: .done, word: "Done · plan_mismatch")])
    }

    // MARK: - Placement in a run

    func testAFactOutsideEveryStepIsTheRunsOwnAndAStepsCompletionIsItsSteps() throws {
        let qa = try run("ticket-facts", "QA run 1")
        // The verdict (10:51) after both steps: the run's own.
        XCTAssertEqual(qa.facts.count, 1)
        guard case let .verdict(verdict) = qa.facts.first?.kind else { return XCTFail("the QA verdict is not the run's") }
        XCTAssertEqual(verdict.word, "Passed")
        // check_1's completion (10:46) is check_1's, though walk_2_3 started the same minute.
        XCTAssertTrue(qa.steps[0].facts.contains { $0.id == "fx-12|answer" || $0.id == "fx-12" })
        XCTAssertFalse(qa.steps[1].facts.contains { $0.id.hasPrefix("fx-12") })
        let review = try run("ticket-facts", "Code Review run 1")
        guard case let .verdict(rework) = review.facts.first?.kind else { return XCTFail("the review's verdict is not the run's") }
        XCTAssertEqual(rework.state, .sentBack)
        XCTAssertEqual(rework.findings.map(\.linesText), ["42–47", "9"])
    }
}
