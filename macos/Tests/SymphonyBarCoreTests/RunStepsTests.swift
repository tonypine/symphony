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
        // The model by its name, its effort apart (TP-1487); the line under the head says the model, time and tokens.
        XCTAssertEqual(run.model, "Claude Opus 5.5")
        XCTAssertEqual(run.effort, "high")
        XCTAssertEqual(run.meta, "Claude Opus 5.5 · 22 min · 1.8M tokens")
        XCTAssertFalse(run.opensByDefault)
        XCTAssertEqual(run.steps.map(\.title), ["Write the code", "Build", "Checks", "Tests"])
        XCTAssertEqual(run.steps.map(\.state), [.done, .done, .skipped, .failed])
        XCTAssertEqual(run.whereText, "stopped at Tests")
        XCTAssertEqual(run.accessibilityLabel, "Implementation run 1, failed, stopped at Tests, 22 minutes, 1.8M tokens, Claude Opus 5.5")
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
        XCTAssertNil(group.model)
        XCTAssertEqual(group.effort, "low")
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
                                    startedAt: "2026-10-07T10:00:00Z", endedAt: "2026-10-07T10:03:00Z", head: nil, model: "m", effort: nil,
                                    outcome: "Pushed and handed off"),
            events: [event("a", "step.completed", "2026-10-07T10:01:00Z", .init(outcome: "skipped", stepID: "qa"))],
            reference: reference
        )
        // A running run has no outcome yet, whatever the header says.
        let live = RunGroupModel.group(
            TicketEventsPayload.Run(runID: "l", status: "running", startedAt: "2026-10-07T10:00:00Z", outcome: "Approved"),
            events: [], reference: reference
        )
        XCTAssertNil(live.outcome)
        XCTAssertEqual(passed.outcome, "Pushed and handed off")
        XCTAssertEqual(passed.title, "Agent run")
        XCTAssertEqual(passed.state, .passed)
        XCTAssertEqual(passed.durationSeconds, 180)
        XCTAssertEqual(passed.model, "M")
        XCTAssertEqual(passed.meta, "M · 3 min · Pushed and handed off")
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
        XCTAssertEqual(group.state, .sentBack)
        XCTAssertEqual(group.word, "Request changes")
        XCTAssertEqual(RunGroupModel.State.allStatuses, [.working, .done, .problem, .idle])
    }

    func testTheRunNowsStepOpensAsItGoesLiveAndKeepsThePersonsOwnFold() {
        var folds = FoldState()
        // A step just started, with no line yet, opens and says nothing is missing.
        let started = RunStep(id: "code", stepID: "code", title: "Write the code", state: .current)
        XCTAssertTrue(started.canUnfold)
        XCTAssertNil(started.cannotUnfoldReason)
        XCTAssertTrue(folds.isUnfolded(started))
        // The next read brings its first line: still open, with nothing the person did.
        var gainedALine = started
        gainedALine.liveLines = [TranscriptLine(kind: .say, text: "Reading the ticket")]
        XCTAssertTrue(folds.isUnfolded(gainedALine))
        // The run moves on: the step it ended is done and folds, the new one opens.
        let done = RunStep(id: "code", stepID: "code", title: "Write the code", state: .done)
        let next = RunStep(id: "tests", stepID: "tests", title: "Tests", state: .current)
        XCTAssertFalse(folds.isUnfolded(done))
        XCTAssertTrue(folds.isUnfolded(next))
        // A fold the person made stays as they left it, whatever the read brings.
        folds.toggle(next)
        XCTAssertFalse(folds.isUnfolded(next))
        var nextWithLines = next
        nextWithLines.liveLines = gainedALine.liveLines
        XCTAssertFalse(folds.isUnfolded(nextWithLines))
        folds.toggle(nextWithLines)
        XCTAssertTrue(folds.isUnfolded(nextWithLines))
        // A step with nothing to show never opens, even when asked.
        let empty = RunStep(id: "build", stepID: "build", title: "Build", state: .done)
        folds.toggle(empty)
        XCTAssertFalse(folds.isUnfolded(empty))
    }

    func testAPinnedFoldStateOpensOnlyTheStepsItNames() {
        let failed = RunStep(id: "tests", stepID: "tests", title: "Tests", state: .failed, transcript: nil, liveLines: [TranscriptLine(kind: .say, text: "x")])
        let current = RunStep(id: "code#2", stepID: "code", title: "Write the code", state: .current)
        let folds = FoldState(ids: ["tests", "code#2", "tests"], unfolded: ["code#2"])
        XCTAssertEqual(folds.overrides, ["tests": false, "code#2": true])
        XCTAssertFalse(folds.isUnfolded(failed))
        XCTAssertTrue(folds.isUnfolded(current))
        var run = FoldState()
        XCTAssertTrue(run.isUnfolded("r", byDefault: true))
        run.toggle("r", byDefault: true)
        XCTAssertFalse(run.isUnfolded("r", byDefault: true))
    }

    func testEachStateHasItsMarkAndWord() {
        let states: [RunStep.State] = [.done, .current, .failed, .paused, .skipped]
        XCTAssertEqual(states.map(\.word), ["Done", "Working", "Failed", "Asked a question", "Skipped"])
        XCTAssertEqual(states.map(\.status), [.done, .working, .problem, .you, .idle])
        XCTAssertEqual(Set(states.map(\.symbol)).count, 5)
        XCTAssertEqual(Set([RunGroupModel.State.running, .passed, .failed, .stopped].map(\.symbol)).count, 4)
        XCTAssertEqual(Set(states.map(\.markSymbol)).count, 5)
        XCTAssertEqual(Set([RunGroupModel.State.running, .passed, .failed, .stopped].map(\.markSymbol)).count, 4)
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

    // MARK: - The model's name (TP-1487)

    func testTheFeedsModelNameWinsAndAnIDReadsAsANameWithout() {
        XCTAssertEqual(ModelName.display("claude-opus-5-5"), "Claude Opus 5.5")
        XCTAssertEqual(ModelName.display("claude-haiku-4-5-20251001"), "Claude Haiku 4.5")
        XCTAssertEqual(ModelName.display("anthropic/claude-sonnet-5-5"), "Claude Sonnet 5.5")
        XCTAssertEqual(ModelName.display("gpt-5.1-codex"), "GPT 5.1 Codex")
        XCTAssertEqual(ModelName.display("model-nightowl"), "Model Nightowl")

        let named = RunGroupModel.group(
            TicketEventsPayload.Run(runID: "n", status: "ended", exit: "handoff", model: "claude-opus-5-5", modelName: "Claude Opus 5.5 (1M)",
                                    effort: "medium"),
            events: [], reference: reference
        )
        XCTAssertEqual(named.model, "Claude Opus 5.5 (1M)")
        XCTAssertEqual(named.effort, "medium")
        XCTAssertNil(RunGroupModel(id: "x", title: "Run", state: .passed, word: "Passed").meta)
    }

    // MARK: - The conversation (TP-1688)

    private static let utc = TimeZone(identifier: "UTC")!

    private func conversation(_ name: String, live: Bool = false) throws -> [ConversationEntry] {
        RunConversation.entries(TranscriptLine.lines(try fixture("artifacts/\(name).ndjson")), live: live, timeZone: Self.utc)
    }

    func testAToolLineCarriesItsToolAndItsFileAsFields() throws {
        let lines = TranscriptLine.lines(try fixture("artifacts/tr-conversation.ndjson"))
        let write = try XCTUnwrap(lines.first { $0.tool == "Write" })
        XCTAssertEqual(write.file, "macos/Sources/SymphonyBarCore/ActivityFilterStore.swift")
        XCTAssertEqual(write.toolName, "Write")
        XCTAssertEqual(write.body, "macos/Sources/SymphonyBarCore/ActivityFilterStore.swift")
        // A blank field is no field; a line saved before Symphony gave them has none.
        let blank = TranscriptLine.lines(Data(#"{"kind":"tool","text":"Bash: ls","tool":" ","file":""}"#.utf8))
        XCTAssertEqual(blank.map(\.tool), [nil])
        XCTAssertEqual(blank.map(\.file), [nil])
        // A live call whose text is only its tool's name has no description to draw.
        XCTAssertEqual(TranscriptLine(kind: .tool, text: "Bash", tool: "Bash").body, "")
        XCTAssertEqual(TranscriptLine(kind: .tool, text: "other words", tool: "Bash").body, "other words")
    }

    func testTheGistAndTheChipsComeFromTheFieldsNeverFromTheText() {
        // Text that reads like a write, with no fields: counted, never named.
        let untold = RunAction(call: TranscriptLine(kind: .tool, text: "Write: lib/x.ex"), result: TranscriptLine(kind: .result, text: "ok"))
        XCTAssertEqual(ActionGist([untold]).count, 1)
        XCTAssertEqual(ActionGist([untold]).parts, [])
        // Fields whose text says something else: the fields win.
        let told = RunAction(call: TranscriptLine(kind: .tool, text: "something else", tool: "Write", file: "a/b/Kept.swift"))
        XCTAssertEqual(ActionGist([told, told]).parts, [.wrote(["Kept.swift"])])
        // Each kind of tool in words, in the order it first came; a write or an edit with no file counts its files.
        let call = { (tool: String, file: String?) in RunAction(call: TranscriptLine(kind: .tool, text: "", tool: tool, file: file)) }
        let gist = ActionGist([
            call("Read", "x.swift"), call("Bash", nil), call("mcp__symphony__ticket_record", nil), call("Bash", nil),
            call("mcp__symphony__ticket_record", nil), call("Grep", nil), call("Edit", nil), call("Write", nil), call("shell", nil),
            call("linear-get_comments", nil), call("MultiEdit", "lib/y.ex"),
        ])
        XCTAssertEqual(gist.parts, [
            .words("read 1 file"), .words("ran 3 commands"), .words("ticket record ×2"), .words("searched 1 time"),
            .edited(["y.ex"]), .words("wrote 1 file"), .words("linear get comments"),
        ])
        XCTAssertEqual(gist.text, "read 1 file, ran 3 commands, ticket record ×2, searched 1 time, edited y.ex, wrote 1 file, linear get comments")
        XCTAssertEqual(ActionGist([call("Edit", nil), call("Edit", nil)]).parts, [.words("edited 2 files")])
        XCTAssertEqual(gist.countText(), "11 actions")
        XCTAssertEqual(ActionGist([call("Bash", nil)]).countText(soFar: true), "1 action so far")
    }

    func testANotesActionsFoldUnderItWithACountAGistAndTheirFilesAsChips() throws {
        let entries = try conversation("tr-conversation")
        XCTAssertEqual(entries.map(\.kind), [.note, .note, .failure, .note, .failure, .actions, .note, .note])
        XCTAssertEqual(entries.map(\.actions.count), [2, 3, 0, 0, 0, 1, 3, 2])
        XCTAssertEqual(entries[0].gist.parts, [.words("read 1 file"), .words("ran 1 command")])
        XCTAssertEqual(entries[1].gist.countText(), "3 actions")
        XCTAssertEqual(entries[1].gist.parts, [.wrote(["ActivityFilterStore.swift", "ActivityFilterStoreTests.swift"]), .edited(["ActivityPane.swift"])])
        XCTAssertEqual(entries[6].gist.parts, [.edited(["Package.swift"]), .words("ran 2 commands")])
        XCTAssertEqual(entries[7].gist.parts, [.words("ran 1 command"), .words("ticket record")])
        // A note with nothing after it draws no fold line.
        XCTAssertFalse(entries[3].hasFold)
        XCTAssertTrue(entries[0].hasFold)
        // Actions after a failure, before the next note, are a fold of their own: no sentence is made up for them.
        XCTAssertNil(entries[5].note)
    }

    func testASilentStretchIsOneFoldedLineThenTheRedTestsOwnRow() throws {
        let entries = try conversation("tr-silent")
        XCTAssertEqual(entries.map(\.kind), [.actions, .failure])
        XCTAssertNil(entries[0].note)
        XCTAssertEqual(entries[0].gist.countText(), "23 actions")
        XCTAssertEqual(entries[0].gist.text, "read 1 file, ran 22 commands")
        // The red test is never in the fold.
        XCTAssertFalse(entries[0].actions.contains(where: \.failed))
        let red = try XCTUnwrap(entries[1].failure)
        XCTAssertEqual(red.call?.toolName, "Bash")
        XCTAssertEqual(red.firstLines().count, 4)
        XCTAssertEqual(red.firstLines().last, "Executed 4 tests, with 1 failure (0 unexpected) in 0.031 (0.034) seconds")
        XCTAssertEqual(red.firstLines(1), ["Test Case '-[SymphonyBarCoreTests.ActivityFilterTests testTheFilterSurvivesARelaunch]' started."])
    }

    func testTheSameFailureBackToBackIsOneRowWithItsCount() throws {
        let entries = try conversation("tr-conversation")
        XCTAssertEqual(entries.filter { $0.kind == .failure }.map(\.repeats), [1, 3])
        // A different answer is a failure of its own.
        let call = TranscriptLine(kind: .tool, text: "Bash: mix test", tool: "Bash")
        let red = { (text: String) in [call, TranscriptLine(kind: .result, text: text, failed: true)] }
        let rows = RunConversation.entries(red("1 failure") + red("1 failure") + red("2 failures"))
        XCTAssertEqual(rows.map(\.repeats), [2, 1])
        XCTAssertTrue(RunAction(call: call, result: TranscriptLine(kind: .result, text: "x", failed: true)).isSameFailure(as: RunAction(call: call, result: TranscriptLine(kind: .result, text: "x", failed: true))))
        XCTAssertFalse(RunAction(call: call, result: TranscriptLine(kind: .result, text: "x")).isSameFailure(as: RunAction(call: call, result: TranscriptLine(kind: .result, text: "x"))))
    }

    func testTheMinuteShowsAboveAnEntryOnlyWhenItChanges() throws {
        XCTAssertEqual(try conversation("tr-conversation").map(\.minute), ["09:30", "09:31", nil, "09:32", nil, "09:35", nil, "09:38"])
        XCTAssertEqual(try conversation("tr-silent").map(\.minute), ["09:30", "09:33"])
        // An entry with no time shows none and leaves the minute as it was.
        let untimed = RunConversation.entries([
            TranscriptLine(kind: .say, text: "a", at: "2026-10-07T09:30:00Z"), TranscriptLine(kind: .say, text: "b"),
            TranscriptLine(kind: .say, text: "c", at: "2026-10-07T09:30:40Z"),
        ], timeZone: Self.utc)
        XCTAssertEqual(untimed.map(\.minute), ["09:30", nil, nil])
    }

    func testWhileTheRunWorksItsLastEntryIsWorkingWithItsActionsSoFar() throws {
        let live = try conversation("tr-conversation", live: true)
        XCTAssertEqual(live.map(\.working), [false, false, false, false, false, false, false, true])
        XCTAssertEqual(live.last?.gist.countText(soFar: true), "2 actions so far")
        XCTAssertFalse(try conversation("tr-conversation").contains(where: \.working))
        // A note the run just wrote has its fold line for "Working" before its first action.
        let fresh = RunConversation.entries([TranscriptLine(kind: .say, text: "Starting.")], live: true)
        XCTAssertTrue(fresh[0].hasFold)
        XCTAssertEqual(fresh[0].gist.count, 0)
        XCTAssertEqual(RunConversation.entries([], live: true), [])
    }

    func testCallsMadeTogetherGetTheirResultsInOrderAndAResultWithoutACallStandsAlone() {
        let a = TranscriptLine(kind: .tool, text: "Read: a", tool: "Read"), b = TranscriptLine(kind: .tool, text: "Read: b", tool: "Read")
        let ra = TranscriptLine(kind: .result, text: "A"), rb = TranscriptLine(kind: .result, text: "B", failed: true)
        let entries = RunConversation.entries([a, b, ra, rb, TranscriptLine(kind: .result, text: "lost")])
        XCTAssertEqual(entries.map(\.kind), [.actions, .failure, .actions])
        XCTAssertEqual(entries[0].actions, [RunAction(call: a, result: ra)])
        XCTAssertEqual(entries[1].failure, RunAction(call: b, result: rb))
        XCTAssertEqual(entries[2].actions, [RunAction(result: TranscriptLine(kind: .result, text: "lost"))])
        // A call still running has no result yet.
        XCTAssertEqual(RunConversation.entries([a]).first?.actions, [RunAction(call: a)])
    }

    func testShowAllUnfoldsEveryGroupAndAClickUnfoldsOnlyItsOwn() {
        var folds = ConversationFolds()
        let ids = ["a", "b", "c"]
        folds.toggle("b", among: ids)
        XCTAssertEqual(ids.map(folds.isOpen), [false, true, false])
        folds.toggle("b", among: ids)
        XCTAssertEqual(ids.map(folds.isOpen), [false, false, false])
        folds.toggleAll()
        XCTAssertEqual(ids.map(folds.isOpen), [true, true, true])
        // A click with every group shown folds that one alone.
        folds.toggle("a", among: ids)
        XCTAssertEqual(ids.map(folds.isOpen), [false, true, true])
        XCTAssertFalse(folds.showsAll)
        folds.toggleAll()
        folds.toggleAll()
        XCTAssertEqual(ids.map(folds.isOpen), [false, false, false])
        XCTAssertEqual(ConversationFolds.showAll, "Show all events")
    }

    /// The ticket-page fixture QA walks (`Fixtures/director-app/ticket-steps`, written by Symphony's server): SHOP-410's
    /// second run, whose code step's transcript holds a silent stretch, notes, a repeated failure, and its third run,
    /// live on that step.
    func testTheStepFixtureDrawsAFinishedStepAndTheRunNowAsConversations() throws {
        let api = Self.fixtures.deletingLastPathComponent().appendingPathComponent("director-app/ticket-steps/api/v1")
        let history = try XCTUnwrap(TicketEventsPayload.decode(Data(contentsOf: api.appendingPathComponent("repos/web-shop/tickets/SHOP-410/events.json"))))
        let runNow = try XCTUnwrap(RunNow.decode(issue: Data(contentsOf: api.appendingPathComponent("SHOP-410.json"))))
        let runs = RunGroupModel.groups(history, runNow: runNow, reference: reference)
        XCTAssertEqual(runs.map(\.state).suffix(2), [.passed, .running])
        let latest = Array(runs.suffix(2))

        let finished = try XCTUnwrap(latest[0].steps.first)
        let transcript = try XCTUnwrap(finished.transcript)
        let saved = TranscriptLine.lines(try Data(contentsOf: api.appendingPathComponent(transcript.path.replacingOccurrences(of: "api/v1/", with: "") + ".txt")))
        let entries = RunConversation.entries(saved, timeZone: Self.utc)
        XCTAssertEqual(entries.first?.kind, .actions)
        XCTAssertEqual(entries.first?.gist.text, "read 1 file, ran 22 commands")
        XCTAssertEqual(entries[1].kind, .failure)
        XCTAssertEqual(entries.filter { $0.kind == .failure }.map(\.repeats), [1, 1, 3])
        XCTAssertTrue(entries.contains { $0.gist.parts.contains(.wrote(["ActivityFilterStore.swift", "ActivityFilterStoreTests.swift"])) })

        let live = try XCTUnwrap(latest[1].steps.last)
        XCTAssertTrue(live.isLive)
        let now = RunConversation.entries(live.liveLines, live: true, timeZone: Self.utc)
        XCTAssertEqual(now.map(\.kind), [.actions, .failure, .note])
        XCTAssertEqual(now.last?.working, true)
        XCTAssertEqual(now.last?.gist.countText(soFar: true), "2 actions so far")
    }

    // MARK: - How a run without steps ends (TP-1689)

    private static func reviewFixture() -> URL {
        fixtures.deletingLastPathComponent().appendingPathComponent("director-app/ticket-review-conversation/api/v1")
    }

    /// The review fixture QA walks (`Fixtures/director-app/ticket-review-conversation`): SHOP-410's first Code Review run
    /// ended with a saved session and a verdict that sent the work back, its QA run was blocked, and its second Code
    /// Review run is the run now, on no step.
    private func reviewRuns() throws -> [RunGroupModel] {
        let api = Self.reviewFixture()
        let history = try XCTUnwrap(TicketEventsPayload.decode(Data(contentsOf: api.appendingPathComponent("repos/web-shop/tickets/SHOP-410/events.json"))))
        let runNow = try XCTUnwrap(RunNow.decode(issue: Data(contentsOf: api.appendingPathComponent("SHOP-410.json"))))
        return RunGroupModel.groups(history, runNow: runNow, reference: reference)
    }

    @MainActor
    func testAFinishedRunWithNoStepsKeepsItsConversationFromItsSavedTranscript() async throws {
        let runs = try reviewRuns()
        XCTAssertEqual(runs.map(\.title), ["Implementation run 1", "Code Review run 1", "Rework run 1", "QA run 1", "Code Review run 2"])
        let review = runs[1]
        XCTAssertTrue(review.steps.isEmpty)
        XCTAssertFalse(review.isLive)
        let saved = try XCTUnwrap(review.savedConversation)
        XCTAssertEqual(saved, review.transcript)
        XCTAssertTrue(saved.path.hasSuffix("/lines"))
        XCTAssertTrue(review.hasConversation)

        // The body reads the session's lines as a step's transcript is read, and draws the same entries as while it ran:
        // the six actions folded into one line, then the review's note.
        let file = Self.reviewFixture().appendingPathComponent(saved.path.replacingOccurrences(of: "api/v1/", with: "") + ".txt")
        let body = try Data(contentsOf: file)
        let transcripts = StepTranscripts { path in path == saved.path ? .answered(body, statusCode: 200) : .answered(Data(), statusCode: 404) }
        await transcripts.load(saved)?.value
        guard case let .loaded(lines) = transcripts.lines(saved) else { return XCTFail("the saved session was not read") }
        let entries = RunConversation.entries(lines, timeZone: Self.utc)
        XCTAssertEqual(entries.map(\.kind), [.actions, .note])
        XCTAssertEqual(entries[0].actions.count, 6)
        XCTAssertEqual(entries[1].note?.text.hasPrefix("I've finished the review of TP-1644"), true)
        XCTAssertFalse(entries.contains(where: \.working))
    }

    func testARunWithNoStepsAndNothingSavedHasNoConversationAndNoSentence() {
        let finished = RunGroupModel(id: "r", title: "QA run 1", state: .passed, word: "Passed")
        XCTAssertNil(finished.savedConversation)
        XCTAssertFalse(finished.hasConversation)
        // The session reader draws nothing for it either: no step, no session.
        let reader = SessionReader.build(identifier: "SHOP-410", run: finished) { _ in .loading }
        XCTAssertEqual(reader.sections, [])
        XCTAssertNil(reader.session)
        XCTAssertEqual(reader.lines, [])
        // A run with steps keeps its transcript for the reader and draws its steps, not a saved conversation.
        var stepped = finished
        stepped.steps = [RunStep(id: "code", stepID: "code", title: "Write the code", state: .done)]
        stepped.transcript = TicketOutput(id: "t", label: "Session", path: "api/v1/artifacts/t/lines", available: true)
        XCTAssertNil(stepped.savedConversation)
        XCTAssertFalse(stepped.hasConversation)
    }

    func testARunningRunWithNoStepsHasItsConversationAndShowAllEvents() throws {
        let running = try XCTUnwrap(reviewRuns().last)
        XCTAssertEqual(running.state, .running)
        XCTAssertTrue(running.steps.isEmpty)
        XCTAssertTrue(running.hasConversation)
        XCTAssertNil(running.savedConversation)
        let entries = RunConversation.entries(running.liveLines, live: true, timeZone: Self.utc)
        XCTAssertEqual(entries.map(\.kind), [.actions, .note])
        XCTAssertEqual(entries.last?.working, true)
        XCTAssertEqual(entries.last?.gist.countText(soFar: true), "3 actions so far")

        // "Show all events" unfolds every group of the run's conversation; again, it folds them all.
        var folds = ConversationFolds()
        let groups = entries.filter(\.hasFold).map(\.id)
        XCTAssertEqual(groups.count, 2)
        folds.toggleAll()
        XCTAssertEqual(groups.map(folds.isOpen), [true, true])
        folds.toggleAll()
        XCTAssertEqual(groups.map(folds.isOpen), [false, false])
        // A run now with no line yet has nothing to unfold.
        var quiet = running
        quiet.liveLines = []
        XCTAssertFalse(quiet.hasConversation)
    }

    func testAReviewThatSendsTheWorkBackReadsRequestChangesInTheSentBackTreatment() throws {
        let review = try reviewRuns()[1]
        XCTAssertEqual(review.state, .sentBack)
        XCTAssertEqual(review.word, "Request changes")
        XCTAssertEqual(review.state.status, .you)
        XCTAssertEqual(review.state.markSymbol, "arrow.uturn.backward")
        XCTAssertEqual(review.state.badgeSymbol, "arrow.uturn.backward")
        XCTAssertNotEqual(review.state.status, .done)
        XCTAssertNotEqual(review.state.markSymbol, RunGroupModel.State.passed.markSymbol)

        // Both outcomes Symphony records for a Code Review send-back read the same, from the verdict's kind and outcome.
        for outcome in ["request_changes", "rework"] {
            let run = TicketEventsPayload.Run(
                runID: "cr", runKind: "code_review", runNumber: 1, status: "ended", exit: "handoff",
                verdict: TicketEventsPayload.Verdict(kind: "code_review", outcome: outcome)
            )
            let group = RunGroupModel.group(run, events: [], reference: reference)
            XCTAssertEqual(group.state, .sentBack, outcome)
            XCTAssertEqual(group.word, RunGroupModel.requestChanges, outcome)
        }
        // An approve keeps its green check; a QA fail keeps its own word.
        XCTAssertNil(RunGroupModel.State.verdict(kind: "code_review", outcome: "approve"))
        XCTAssertNil(RunGroupModel.State.verdict(kind: "qa", outcome: "fail"))
        XCTAssertEqual(TicketEventsPayload.verdictState(kind: "code_review", outcome: "request_changes").0, .failed)
    }

    func testBlockedIsTheIdleGreyWithAStruckCircleAndAmberIsForWhatWaitsOnYou() throws {
        let qa = try reviewRuns()[3]
        XCTAssertEqual(qa.state, .blocked)
        XCTAssertEqual(qa.word, "Blocked")
        XCTAssertEqual(qa.state.status, .idle)
        XCTAssertEqual(qa.state.markSymbol, "circle.slash")
        XCTAssertEqual(qa.state.badgeSymbol, "circle.slash")
        XCTAssertEqual(RunGroupModel.State.verdict(kind: "code_review", outcome: "block")?.0, .blocked)

        XCTAssertEqual(RunStep.State.blocked.status, .idle)
        XCTAssertEqual(RunStep.State.blocked.markSymbol, "circle.slash")
        XCTAssertEqual(RunStep.State.blocked.symbol, "circle.slash")
        XCTAssertEqual(RunStep.State.blocked.word, "Blocked")

        // Amber (the `you` status) is only for what waits on the person: a question asked, or work sent back.
        let steps: [RunStep.State] = [.done, .current, .failed, .paused, .skipped, .blocked]
        XCTAssertEqual(steps.filter { $0.status == .you }, [.paused])
        let runs: [RunGroupModel.State] = [.running, .passed, .failed, .stopped, .sentBack, .blocked]
        XCTAssertEqual(runs.filter { $0.status == .you }, [.sentBack])
    }

    func testANotesMarkdownReadsAsParagraphsListsCodeAndBold() {
        let markup = RunNote.markup("**Plan:**\n\n* one `x`\n- two\n\n## Then\n1. first\n2. second\n\n```\n# not a heading\n* not a bullet\n```")
        XCTAssertEqual(markup.blocks, [
            .paragraph([.bold([.plain("Plan:")])]),
            .list([[.plain("one "), .code("x")], [.plain("two")]]),
            .paragraph([.bold([.plain("Then")]), .plain("\n1. first\n2. second")]),
            .codeBlock([.init(text: "# not a heading", change: .unchanged), .init(text: "* not a bullet", change: .unchanged)]),
        ])
        // A note has no headline: every paragraph is body text.
        XCTAssertEqual(markup.roles, [.body, .body, .body, .body])
        XCTAssertNil(RunNote.heading("#nospace"))
        XCTAssertNil(RunNote.heading("# "))
        XCTAssertNil(RunNote.heading("####### seven"))
        // Plain words stay whole, never cut.
        let long = String(repeating: "word ", count: 400).trimmingCharacters(in: .whitespaces)
        XCTAssertEqual(RunNote.markup(long).plainText, long)
    }

}

private extension RunGroupModel.State {
    static var allStatuses: [DesignTokens.Status] { [RunGroupModel.State.running, .passed, .failed, .stopped].map(\.status) }
}
