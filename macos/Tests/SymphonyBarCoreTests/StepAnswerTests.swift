@testable import SymphonyBarCore
import XCTest

/// A stepped QA pass's answers on the steps' own completions (`result`, `plan`, `recheck`, `verdict_summary`, `reason`),
/// and the old machine-written notes that held them before: from `Tests/Fixtures/timeline/qa-steps.json`.
final class StepAnswerTests: XCTestCase {
    private static let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/timeline/qa-steps.json")

    private let reference = ISO8601DateFormatter().date(from: "2026-10-08T10:00:00Z")!

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func history() throws -> TicketEventsPayload { try XCTUnwrap(TicketEventsPayload.decode(Data(contentsOf: Self.fixture))) }

    private func answer(_ payload: String) throws -> StepAnswer? {
        let page = #"{"timeline":[{"kind":"run","run_id":"qa-1","run_kind":"qa","run_number":1,"status":"ended","started_at":"2026-10-08T09:00:00Z","events":[{"id":"e1","at":"2026-10-08T09:01:00Z","type":"step.completed","run_id":"qa-1","payload":\#(payload),"artifacts":[],"children":[]}]}]}"#
        return try XCTUnwrap(TicketEventsPayload.decode(Data(page.utf8))).events[0].payload.answer
    }

    // MARK: - Decoding

    func testAResultReadsItsStatusExpectedAndActual() throws {
        let read = try XCTUnwrap(answer(#"{"step_id":"c","outcome":"failed","result":{"status":"blocked","expected":"A row","actual":"None"}}"#))
        XCTAssertEqual(read.result, .init(status: "blocked", expected: "A row", actual: "None"))
        XCTAssertNil(read.result?.extraWord, "the step's state says blocked")
        XCTAssertEqual(StepAnswer.Result(status: "plan_mismatch", expected: nil, actual: nil).extraWord, "plan_mismatch")
        XCTAssertNil(StepAnswer.Result(status: "failed", expected: nil, actual: nil).extraWord)
        XCTAssertNil(StepAnswer.Result(status: "Passed", expected: nil, actual: nil).extraWord)
    }

    func testAGroupedWalkReadsOneResultPerWalkthroughStep() throws {
        let read = try XCTUnwrap(answer(#"{"results":[{"step":1,"status":"pass","expected":"A","actual":"A"},{"step":2,"status":"fail","expected":"B","actual":"C"},{"step":3,"status":"plan_mismatch"},{"expected":"no status"},7]}"#))
        XCTAssertNil(read.result)
        XCTAssertEqual(read.results.map(\.step), [1, 2, 3])
        XCTAssertEqual(read.results.map(\.title), ["Step 1", "Step 2", "Step 3"])
        XCTAssertEqual(read.results.map(\.state), [.done, .failed, .done])
        XCTAssertEqual(read.results.map(\.word), ["Done", "Failed", "Done · plan_mismatch"])
        XCTAssertEqual(read.results[1].accessibilityLabel, "Step 2, failed, C")
        XCTAssertEqual(StepAnswer.CheckResult(step: nil, result: .init(status: "blocked")).title, "Check")
        XCTAssertEqual(read.judgement, .failed, "the step reads its worst check")
        XCTAssertFalse(read.isEmpty)
    }

    func testAGroupedWalksStateIsItsWorstCheck() {
        func judged(_ statuses: [String]) -> RunStep.State? {
            StepAnswer(results: statuses.enumerated().map { .init(step: $0.offset + 1, result: .init(status: $0.element)) }).judgement
        }
        XCTAssertEqual(judged(["pass", "blocked", "pass"]), .blocked)
        XCTAssertEqual(judged(["blocked", "fail"]), .failed)
        XCTAssertEqual(judged(["pass", "pass"]), .done)
        XCTAssertNil(judged(["pass", "plan_mismatch"]))
        XCTAssertNil(StepAnswer().judgement)
        XCTAssertEqual(StepAnswer(result: .init(status: "blocked")).judgement, .blocked)
    }

    @MainActor
    func testTheGroupedWalkFixtureListsEachCheckWithItsOwnResult() throws {
        let feed = TicketEventsTests.director("ticket-grouped-walk").appendingPathComponent("api/v1/repos/web-shop/tickets/SHOP-410/events.json")
        let history = try XCTUnwrap(TicketEventsPayload.decode(Data(contentsOf: feed)))
        let run = try XCTUnwrap(RunGroupModel.groups(history, reference: reference).first { $0.id == "run-qa-1" })
        let walk = try XCTUnwrap(run.steps.first { $0.stepID == "walk_1_2_3" })
        XCTAssertEqual(walk.title, "Walk a step 1, 2, 3")
        XCTAssertEqual(walk.state, .failed, "the group reads its failed check")
        XCTAssertFalse(walk.stopsTheRun, "a check that judged the change failed did not stop the run")
        let checks = try XCTUnwrap(walk.answer?.results)
        XCTAssertEqual(checks.map(\.title), ["Step 1", "Step 2", "Step 3"])
        XCTAssertEqual(checks.map(\.state), [.done, .failed, .done])
        XCTAssertEqual(checks[1].result.actual, "Agents shows two rows; Codex is missing")
        XCTAssertEqual(run.steps.first { $0.stepID == "walk_4" }?.state, .done)
    }

    /// QA opens SHOP-410 from Work › Tickets: every list the app reads on the way is answered, and Tickets lists it.
    func testTheGroupedWalkFixtureReachesItsTicketFromTickets() throws {
        let api = TicketEventsTests.director("ticket-grouped-walk")
        func read(_ path: String) throws -> Data { try Data(contentsOf: api.appendingPathComponent(path + ".json")) }
        let tickets = try XCTUnwrap(TicketsPayload.decode(try read(TicketsPayload.path)))
        XCTAssertEqual(tickets.rows.map(\.identifier), ["SHOP-410"])
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: try read(TicketsPayload.viewsPath)) as? [String: Any])
        XCTAssertNotNil(HomeRead.decode(try read(HomeRead.path)))
        XCTAssertNotNil(InboxPayload.decode(try read(InboxPayload.path)))
        XCTAssertNotNil(InitiativesPayload.decode(try read(InitiativesPayload.path)))
    }

    func testAPlanReadsItsSummaryChecksAndSkips() throws {
        let read = try XCTUnwrap(answer(#"{"plan":{"summary":"Three checks.","checks":[{"title":"A","expect":"a"},{"title":"B"},{"expect":"no title"}],"skips":[{"title":"C","why":"Not here"},{"why":"no title"}]}}"#)).plan
        XCTAssertEqual(read?.summary, "Three checks.")
        XCTAssertEqual(read?.checks, [.init(title: "A", expect: "a"), .init(title: "B", expect: nil)])
        XCTAssertEqual(read?.skips, [.init(title: "C", why: "Not here")])
    }

    func testARecheckReadsItsInstructionsAsAList() throws {
        let read = try XCTUnwrap(answer(#"{"recheck":[{"title":"Row in dark","do":["Open it"," Read the row ",7,""],"expect":"Problem mark","design":"d"},{"do":["no title"]}]}"#))
        XCTAssertEqual(read.rechecks, [.init(title: "Row in dark", instructions: ["Open it", "Read the row"], expect: "Problem mark", design: "d")])
    }

    func testAVerdictSummaryIsOneParagraph() throws {
        XCTAssertEqual(try answer(#"{"verdict_summary":" QA found one defect. "}"#)?.verdictSummary, "QA found one defect.")
    }

    func testEveryFieldIsOptionalAndAnUnknownShapeIsSkipped() throws {
        XCTAssertNil(try answer(#"{"step_id":"c","outcome":"passed"}"#))
        XCTAssertNil(try answer(#"{"result":"passed","plan":[1],"recheck":"again","verdict_summary":7}"#))
        XCTAssertNil(try answer(#"{"result":{},"plan":{"checks":[]},"recheck":[]}"#))
        let partial = try XCTUnwrap(answer(#"{"result":{"expected":"x"},"plan":7,"recheck":{"title":"not a list"}}"#))
        XCTAssertEqual(partial.result?.expected, "x")
        XCTAssertNil(partial.plan)
        XCTAssertEqual(partial.rechecks, [])
    }

    func testAStepsReasonStaysInItsRow() throws {
        let page = #"{"timeline":[{"kind":"run","run_id":"qa-1","run_kind":"qa","status":"ended","events":[{"id":"e1","at":"2026-10-08T09:01:00Z","type":"step.completed","run_id":"qa-1","payload":{"step_id":"c","title":"Check","outcome":"passed","reason":"Symphony could not take its answer"},"artifacts":[],"children":[]}]}]}"#
        let run = try XCTUnwrap(RunGroupModel.groups(try XCTUnwrap(TicketEventsPayload.decode(Data(page.utf8))), reference: reference).first)
        XCTAssertEqual(run.steps.first?.reason, "Symphony could not take its answer")
    }

    // MARK: - On the step

    func testAStepThatCarriesAnAnswerCanUnfold() throws {
        let run = try XCTUnwrap(RunGroupModel.groups(history(), reference: reference).first { $0.id == "qa-1" })
        XCTAssertEqual(run.steps.map(\.title), ["Plan the pass", "Check: Needs-a-fix row", "Check: Done recently card", "Review", "Verdict"])
        XCTAssertTrue(run.steps.allSatisfy(\.canUnfold), "each step has an answer, though none has a transcript")
        XCTAssertNotNil(run.steps[0].answer?.plan)
        XCTAssertEqual(run.steps[1].answer?.result?.status, "fail")
        XCTAssertEqual(run.steps.map(\.state), [.done, .failed, .blocked, .done, .done], "each check reads what it judged, as Symphony records it")
        XCTAssertEqual(run.steps[2].answer?.result?.judgement, .blocked)
        XCTAssertEqual(run.steps[3].answer?.rechecks.count, 2)
        XCTAssertNotNil(run.steps[4].answer?.verdictSummary)
        XCTAssertFalse(RunStep(id: "a", stepID: "a", title: "A", state: .done).canUnfold)
    }

    // MARK: - The old notes

    func testTheOldMachineNotesOfAQARunFoldBehindShowAllEvents() throws {
        let model = TimelineModel.build(try history(), reference: reference, calendar: utc)
        XCTAssertNil(model.showing(allEvents: false).items.first { $0.id == "entry-qn" }, "not on the main timeline")
        let all = model.showing(allEvents: true)
        let note = try XCTUnwrap(all.items.first { $0.id == "entry-qn" }, "still reachable")
        XCTAssertTrue(note.isMechanical)
    }

    func testOnlyTheOldShapesOfNotesUnderAQARunAreMachineWritten() throws {
        func note(_ text: String, kind: String = "qa") throws -> Bool {
            let json = text.replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\"", with: "\\\"")
            let page = #"{"timeline":[{"kind":"run","run_id":"qa-1","run_kind":"\#(kind)","status":"ended","events":[{"id":"n1","at":"2026-10-08T09:01:00Z","type":"note","run_id":"qa-1","payload":{"text":"\#(json)"},"artifacts":[],"children":[]}]}]}"#
            let history = try XCTUnwrap(TicketEventsPayload.decode(Data(page.utf8)))
            return TimelineModel.isMachineNote(history.events[0], history: history)
        }
        XCTAssertTrue(try note("Check: Needs-a-fix row: failed. Expected: A row. Actual: none."))
        XCTAssertTrue(try note("Plan the pass: blocked. Expected: a plan"))
        XCTAssertTrue(try note("The QA review asked for a recheck of 2 checks:\n[{\"title\":\"x\"}]"))
        XCTAssertTrue(try note("The Verdict step of the QA pass gave no answer Symphony takes."))
        XCTAssertFalse(try note("QA found the row fine. Expected nothing more."))
        XCTAssertFalse(try note("Remember to check dark mode."))
        XCTAssertFalse(try note("Check: Row: failed. Expected: A row", kind: "implementation"), "only under a QA run")
        // A note under no run is a person's.
        let page = #"{"timeline":[{"id":"n2","at":"2026-10-08T09:01:00Z","type":"note","payload":{"text":"The QA review asked for a recheck of 1 check"},"artifacts":[],"children":[]}]}"#
        let history = try XCTUnwrap(TicketEventsPayload.decode(Data(page.utf8)))
        XCTAssertFalse(TimelineModel.isMachineNote(history.events[0], history: history))
    }

    func testEveryOtherNoteStaysOnTheTimeline() throws {
        let page = #"{"timeline":[{"id":"n3","at":"2026-10-08T09:01:00Z","type":"note","actor":{"kind":"person","name":"Tony"},"payload":{"text":"Watch the dark clock."},"artifacts":[],"children":[]}]}"#
        let model = TimelineModel.build(try XCTUnwrap(TicketEventsPayload.decode(Data(page.utf8))), reference: reference, calendar: utc)
        XCTAssertEqual(model.showing(allEvents: false).items.map(\.id), ["entry-n3"])
    }
}
