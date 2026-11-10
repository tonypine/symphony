import Foundation
@testable import SymphonyBarCore
import XCTest

/// A run folded into its steps and a step into its transcript lines, from the fixture in `Tests/Fixtures/run-steps`:
/// TP-1376's run 1, which failed on its tests, and its run 2, live on its tests step.
final class RunStepsTests: XCTestCase {
    private static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/run-steps")

    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: Self.fixtures.appendingPathComponent(name))
    }

    private let reference = ISO8601DateFormatter().date(from: "2026-10-07T12:27:00Z")!

    private func groups() throws -> [RunGroupModel] {
        let history = try XCTUnwrap(TicketEventsPayload.decode(fixture("events.json")))
        let runNow = try XCTUnwrap(RunNow.decode(issue: fixture("issue.json")))
        return RunGroupModel.groups(history, runNow: runNow, liveTokens: 920_000, reference: reference)
    }

    // MARK: - Transcript lines

    func testATranscriptArtifactDecodesIntoWhatTheAgentSaidItsToolCallsAndWhatCameBack() throws {
        let lines = TranscriptLine.lines(try fixture("artifacts/tr-tests-1.ndjson"))
        // The line of a kind the app doesn't know and the line that isn't JSON are skipped.
        XCTAssertEqual(lines.map(\.kind), [.say, .tool, .result, .say, .tool, .result])
        XCTAssertEqual(lines[1].toolName, "Bash")
        XCTAssertEqual(lines[1].body, "mix test test/symphony_elixir/orchestrator_test.exs")
        XCTAssertEqual(lines[2].failed, true)
        XCTAssertEqual(lines[2].durationMs, 68_000)
        XCTAssertEqual(lines[2].durationText, "1 min 8 s")
        XCTAssertEqual(lines[5].failed, false)
        XCTAssertEqual(lines[5].durationText, "140 ms")
        XCTAssertEqual(lines[0].date, ISO8601DateFormatter().date(from: "2026-10-07T09:14:02Z"))
        XCTAssertNil(lines[0].toolName)
        XCTAssertEqual(lines[0].body, lines[0].text)
    }

    func testDurationsReadInTheirUnit() {
        XCTAssertEqual(TranscriptLine.duration(-5), "0 ms")
        XCTAssertEqual(TranscriptLine.duration(1_240), "1.2 s")
        XCTAssertEqual(TranscriptLine.duration(42_000), "42 s")
        XCTAssertEqual(TranscriptLine.duration(120_000), "2 min")
    }

    func testAToolCallWithoutANameBeforeAColonIsAllBody() {
        let bare = TranscriptLine(kind: .tool, text: "Bash")
        XCTAssertNil(bare.toolName)
        XCTAssertEqual(bare.body, "Bash")
        XCTAssertNil(TranscriptLine(kind: .tool, text: ": nothing").toolName)
        XCTAssertNil(TranscriptLine(kind: .tool, text: "read the file: now").toolName)
    }

    func testEachLineReadsForVoiceOver() {
        XCTAssertEqual(TranscriptLine(kind: .say, text: "Hi").accessibilityLabel, "The agent said: Hi")
        XCTAssertEqual(TranscriptLine(kind: .tool, text: "Bash: ls").accessibilityLabel, "Tool call Bash: ls")
        XCTAssertEqual(TranscriptLine(kind: .result, text: "boom", durationMs: 1_200, failed: true).accessibilityLabel, "Result, failed, 1.2 s: boom")
        XCTAssertEqual(TranscriptLine(kind: .result, text: "ok").accessibilityLabel, "Result: ok")
    }

    // MARK: - The run now

    func testTheTicketReadGivesTheRunNowsStepAndItsNewestLines() throws {
        let runNow = try XCTUnwrap(RunNow.decode(issue: fixture("issue.json")))
        XCTAssertEqual(runNow.currentStep, RunNow.CurrentStep(id: "tests", title: "Tests", startedAt: "2026-10-07T11:57:10Z"))
        // The line of an unknown kind is dropped, the others kept.
        XCTAssertEqual(runNow.lines.map(\.kind), [.say, .tool, .result, .say])
        XCTAssertNil(RunNow.decode(issue: Data(#"{"status":"todo"}"#.utf8)))
        XCTAssertNil(RunNow.decode(issue: Data("not json".utf8)))
        XCTAssertEqual(RunNow.decode(issue: Data(#"{"running":{}}"#.utf8)), RunNow(currentStep: nil, lines: []))
    }

    func testTheTicketPageCarriesTheRunNow() throws {
        let page = TicketPage(identifier: "TP-1376", sources: TicketPage.Sources(issue: try fixture("issue.json")))
        XCTAssertEqual(page.runNow?.currentStep?.id, "tests")
        XCTAssertNil(TicketPage(identifier: "TP-1376", sources: TicketPage.Sources()).runNow)
    }

    // MARK: - Run groups

    func testAnEndedRunIsFoldedWithItsHeaderAndAStepPerStep() throws {
        let run = try XCTUnwrap(groups().first)
        XCTAssertEqual(run.title, "Implementation run 1")
        XCTAssertEqual(run.state, .failed)
        XCTAssertEqual(run.word, "Failed")
        XCTAssertEqual(run.durationSeconds, 1_320)
        XCTAssertEqual(run.duration, "22 min")
        XCTAssertEqual(run.tokens, 1_840_000)
        XCTAssertEqual(run.tokensText, "1.8M tokens")
        XCTAssertEqual(run.model, "claude-opus-5-5 · high")
        XCTAssertFalse(run.opensByDefault)
        XCTAssertEqual(run.steps.map(\.title), ["Write the code", "Build", "Checks", "Tests"])
        XCTAssertEqual(run.steps.map(\.state), [.done, .done, .skipped, .failed])
        XCTAssertEqual(run.whereText, "stopped at Tests")
        XCTAssertEqual(run.accessibilityLabel, "Implementation run 1, failed, stopped at Tests, 22 minutes, 1.8M tokens, claude-opus-5-5 · high")
        XCTAssertEqual(run.foldAccessibilityLabel(folded: true), "Expand Implementation run 1, failed")
        XCTAssertEqual(run.foldAccessibilityLabel(folded: false), "Collapse Implementation run 1, failed")
    }

    func testEachStepSaysItsStateItsReasonAndWhetherItCanUnfold() throws {
        let steps = try XCTUnwrap(groups().first).steps
        let (code, build, checks, tests) = (steps[0], steps[1], steps[2], steps[3])
        XCTAssertEqual(code.durationSeconds, 480)
        XCTAssertEqual(code.transcript?.path, "api/v1/artifacts/tr-code-1")
        XCTAssertTrue(code.canUnfold)
        XCTAssertFalse(code.opensByDefault)
        // A machine step with no transcript can't unfold, and says so on hover.
        XCTAssertEqual(build.durationSeconds, 120)
        XCTAssertFalse(build.canUnfold)
        XCTAssertEqual(build.cannotUnfoldReason, RunStep.nothingYet)
        XCTAssertEqual(checks.reason, "no Elixir file changed")
        XCTAssertEqual(checks.accessibilityLabel, "Checks, skipped, no Elixir file changed")
        XCTAssertNil(checks.durationSeconds)
        // The failed step starts unfolded inside its ended run.
        XCTAssertEqual(tests.reason, "back to Write the code")
        XCTAssertTrue(tests.opensByDefault)
        XCTAssertNil(tests.cannotUnfoldReason)
        XCTAssertEqual(tests.foldAccessibilityLabel(folded: true), "Expand Tests, failed")
        XCTAssertEqual(tests.duration, "2 min")
    }

    func testTheRunNowIsUnfoldedLiveOnItsCurrentStepWithTheNewestLines() throws {
        let run = try XCTUnwrap(groups().last)
        XCTAssertEqual(run.state, .running)
        XCTAssertEqual(run.word, "Running")
        XCTAssertTrue(run.opensByDefault)
        XCTAssertEqual(run.duration, "42 min so far")
        XCTAssertEqual(run.tokens, 920_000)
        XCTAssertEqual(run.steps.map(\.state), [.done, .done, .current])
        XCTAssertEqual(run.whereText, "on Tests")
        let current = try XCTUnwrap(run.steps.last)
        XCTAssertTrue(current.isLive)
        XCTAssertTrue(current.opensByDefault)
        XCTAssertEqual(current.durationSeconds, 1_790)
        XCTAssertEqual(current.liveLines.count, 4)
        XCTAssertEqual(current.state.word, "Working")
    }

    func testARunNowsStepTheFeedHasNotWrittenYetComesFromTheTicketRead() {
        var history = TicketEventsPayload()
        let page = #"{"timeline":[{"kind":"run","run_id":"r","run_kind":"qa","run_number":1,"status":"running","started_at":"2026-10-07T12:00:00Z","events":[]}]}"#
        history.merge(TicketEventsPayload.decode(Data(page.utf8))!)
        let runNow = RunNow(currentStep: .init(id: "walk", title: nil, startedAt: "2026-10-07T12:20:00Z"), lines: [TranscriptLine(kind: .say, text: "Walking")])
        let run = RunGroupModel.groups(history, runNow: runNow, reference: reference)[0]
        XCTAssertEqual(run.title, "QA run 1")
        XCTAssertEqual(run.durationSeconds, 1_620)
        XCTAssertNil(run.model)
        XCTAssertEqual(run.steps.map(\.title), ["walk"])
        XCTAssertEqual(run.steps[0].durationSeconds, 420)
        XCTAssertEqual(run.steps[0].liveLines.map(\.text), ["Walking"])
        // Between steps the read names none, and a run with no step names nowhere.
        let between = RunGroupModel.groups(history, runNow: RunNow(currentStep: nil, lines: []), reference: reference)[0]
        XCTAssertTrue(between.steps.isEmpty)
        XCTAssertNil(between.whereText)
        XCTAssertNil(between.stoppedAt)
    }

    func testAStepARunEndedInFailedThereAndARepeatedStepIsNumbered() {
        func event(_ id: String, _ type: String, _ at: String, _ payload: TicketEventsPayload.Payload) -> TicketEventsPayload.Event {
            TicketEventsPayload.Event(id: id, seq: nil, at: at, type: type, runID: "r", parent: nil, actor: nil, summary: nil, payload: payload, artifacts: [])
        }
        let run = TicketEventsPayload.Run(runID: "r", runKind: "implementation", runNumber: 3, status: "ended", exit: "stopped", verdict: nil,
                                          startedAt: nil, endedAt: nil, head: nil)
        let events = [
            event("1", "run.started", "2026-10-07T10:00:00Z", .init(model: " ", effort: "low")),
            event("2", "step.started", "2026-10-07T10:00:00Z", .init(stepID: "code", title: "Write the code")),
            event("3", "step.completed", "2026-10-07T10:01:00Z", .init(outcome: "paused", stepID: "code", questionID: "q1")),
            event("4", "step.started", "2026-10-07T10:05:00Z", .init(stepID: "code")),
            event("5", "step.completed", "2026-10-07T10:06:00Z", .init(outcome: "passed", stepID: "code", title: "Code again")),
            event("6", "step.started", "2026-10-07T10:06:00Z", .init(stepID: "tests", title: "Tests")),
            event("7", "step.completed", "2026-10-07T10:07:00Z", .init(outcome: "failed", stepID: "lint")),
            event("8", "step.started", "2026-10-07T10:07:00Z", .init(stepID: " ")),
            event("9", "run.ended", "2026-10-07T10:10:00Z", .init(exit: "stopped")),
        ]
        let group = RunGroupModel.group(run, events: events, reference: reference)
        XCTAssertEqual(group.state, .stopped)
        XCTAssertEqual(group.word, "Stopped")
        XCTAssertEqual(group.durationSeconds, 600)
        XCTAssertEqual(group.model, "low")
        XCTAssertNil(group.tokensText)
        XCTAssertEqual(group.steps.map(\.id), ["code", "code#2", "tests", "lint"])
        XCTAssertEqual(group.steps.map(\.state), [.paused, .done, .failed, .failed])
        XCTAssertEqual(group.steps[0].reason, "waiting on your answer")
        XCTAssertEqual(group.steps[0].title, "Write the code")
        XCTAssertEqual(group.steps[1].title, "Code again")
        XCTAssertEqual(group.steps[1].durationSeconds, 60)
        XCTAssertEqual(group.steps[2].reason, RunGroupModel.endedInStep)
        XCTAssertNil(group.steps[3].reason)
        XCTAssertNil(group.steps[3].durationSeconds)
        // The step it stopped at is the last that failed or asked.
        XCTAssertEqual(group.whereText, "stopped at lint")

        let passed = RunGroupModel.group(
            TicketEventsPayload.Run(runID: "p", runKind: nil, runNumber: nil, status: "ended", exit: "handoff", verdict: nil,
                                    startedAt: "2026-10-07T10:00:00Z", endedAt: "2026-10-07T10:03:00Z", head: nil, model: "m", effort: nil),
            events: [event("a", "step.completed", "2026-10-07T10:01:00Z", .init(outcome: "skipped", stepID: "qa"))],
            reference: reference
        )
        XCTAssertEqual(passed.title, "Agent run")
        XCTAssertEqual(passed.state, .passed)
        XCTAssertEqual(passed.durationSeconds, 180)
        XCTAssertEqual(passed.model, "m")
        XCTAssertEqual(passed.whereText, "ended after qa")
        XCTAssertNil(passed.steps[0].reason)

        let unknown = RunGroupModel.group(
            TicketEventsPayload.Run(runID: "u", runKind: nil, runNumber: nil, status: "running", exit: nil, verdict: nil,
                                    startedAt: nil, endedAt: nil, head: nil),
            events: [event("b", "step.completed", "2026-10-07T10:01:00Z", .init(outcome: "passed", stepID: "code"))],
            reference: reference
        )
        XCTAssertNil(unknown.durationSeconds)
        XCTAssertNil(unknown.duration)
        XCTAssertEqual(unknown.whereText, "after code")
    }

    func testARunWhoseVerdictFailedReadsAsTheVerdictSays() {
        let run = TicketEventsPayload.Run(
            runID: "v", runKind: "code_review", runNumber: 2, status: "ended", exit: "handoff",
            verdict: .init(kind: "code_review", outcome: "rework", head: nil, at: nil), startedAt: nil, endedAt: nil, head: nil
        )
        let group = RunGroupModel.group(run, events: [], reference: reference)
        XCTAssertEqual(group.state, .failed)
        XCTAssertEqual(group.word, "Sent back")
        XCTAssertEqual(RunGroupModel.State.allStatuses, [.working, .done, .problem, .idle])
    }

    func testEachStateHasItsMarkAndWord() {
        let states: [RunStep.State] = [.done, .current, .failed, .paused, .skipped]
        XCTAssertEqual(states.map(\.word), ["Done", "Working", "Failed", "Asked a question", "Skipped"])
        XCTAssertEqual(states.map(\.status), [.done, .working, .problem, .you, .idle])
        XCTAssertEqual(Set(states.map(\.symbol)).count, 5)
        XCTAssertEqual(Set([RunGroupModel.State.running, .passed, .failed, .stopped].map(\.symbol)).count, 4)
    }

    // MARK: - Reading transcripts

    @MainActor
    func testAStepsTranscriptIsReadOnItsFirstUnfoldAndKept() async throws {
        let data = try fixture("artifacts/tr-tests-1.ndjson")
        var answers: [APIAnswer] = [.unreachable, .answered(data, statusCode: 200)]
        let transcripts = StepTranscripts { _ in answers.removeFirst() }
        let transcript = TicketOutput(id: "tr-tests-1", label: "Tests transcript", path: "api/v1/artifacts/tr-tests-1", available: true)
        XCTAssertEqual(transcripts.lines(transcript), .loading)
        await transcripts.load(transcript)?.value
        XCTAssertEqual(transcripts.lines(transcript), .failed)
        // A failed read is read again on the next unfold; a kept one isn't.
        await transcripts.load(transcript)?.value
        guard case let .loaded(lines) = transcripts.lines(transcript) else { return XCTFail("not loaded") }
        XCTAssertEqual(lines.count, 6)
        XCTAssertNil(transcripts.load(transcript))
        XCTAssertEqual(transcripts.requests, ["api/v1/artifacts/tr-tests-1", "api/v1/artifacts/tr-tests-1"])
    }

    @MainActor
    func testAGoneTranscriptIsUnavailableAndTheOldestKeptGoesPastTheCapacity() async {
        let transcripts = StepTranscripts { path in path.hasSuffix("gone") ? .answered(Data(), statusCode: 410) : .answered(Data(), statusCode: 500) }
        let gone = TicketOutput(id: "gone", label: "t", path: "api/v1/artifacts/gone", available: true)
        await transcripts.load(gone)?.value
        XCTAssertEqual(transcripts.lines(gone), .unavailable)
        XCTAssertNil(transcripts.load(gone))
        let off = TicketOutput(id: "off", label: "t", path: "x", available: false)
        XCTAssertEqual(transcripts.lines(off), .unavailable)
        XCTAssertNil(transcripts.load(off))
        let broken = TicketOutput(id: "broken", label: "t", path: "x", available: true)
        await transcripts.load(broken)?.value
        XCTAssertEqual(transcripts.lines(broken), .failed)
        XCTAssertEqual(StepTranscripts.lines(.answered(Data(), statusCode: 404)), .unavailable)

        for index in 0 ... StepTranscripts.capacity {
            transcripts.keep([TranscriptLine(kind: .say, text: "\(index)")], for: "kept-\(index)")
        }
        transcripts.keep([], for: "kept-1")
        XCTAssertNil(transcripts.transcripts["kept-0"])
        XCTAssertEqual(transcripts.transcripts["kept-1"], .loaded([]))
        XCTAssertNotNil(transcripts.transcripts["kept-\(StepTranscripts.capacity)"])
    }
}

private extension RunGroupModel.State {
    static var allStatuses: [DesignTokens.Status] { [RunGroupModel.State.running, .passed, .failed, .stopped].map(\.status) }
}
