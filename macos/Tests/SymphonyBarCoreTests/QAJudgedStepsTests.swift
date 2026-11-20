@testable import SymphonyBarCore
import XCTest

/// A QA check step is drawn with what it judged (TP-1557): a walk that judged "fail" reads Failed and a design check that
/// judged "blocked" reads Blocked, in the pass's step list and in the Conductor's message under it, from events recorded
/// as they were before (outcome "passed", result status "fail"): `Tests/Fixtures/timeline/qa-judged-steps.json`.
final class QAJudgedStepsTests: XCTestCase {
    private static let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/timeline/qa-judged-steps.json")

    private let reference = ISO8601DateFormatter().date(from: "2026-11-20T12:00:00Z")!

    private func history() throws -> TicketEventsPayload { try XCTUnwrap(TicketEventsPayload.decode(Data(contentsOf: Self.fixture))) }

    private func run() throws -> RunGroupModel {
        try XCTUnwrap(RunGroupModel.groups(history(), reference: reference).first { $0.id == "qa-2" })
    }

    private func stepsBlock(_ id: String, in history: TicketEventsPayload) throws -> ConductorBlock.Steps {
        let event = try XCTUnwrap(history.events.first { $0.id == id })
        let blocks = try XCTUnwrap(ConductorMessage(event: event)).blocks
        guard case let .steps(steps)? = blocks.first else {
            XCTFail("no steps block on \(id)")
            throw CocoaError(.featureUnsupported)
        }
        return steps
    }

    // MARK: - The pass's step list

    func testAPassDrawsEachCheckWithWhatItJudged() throws {
        let run = try run()
        XCTAssertEqual(run.steps.map(\.stepID), ["plan", "walk_1", "design_check", "wide_pass", "review"])
        XCTAssertEqual(run.steps.map(\.state), [.done, .failed, .blocked, .done, .done])
        XCTAssertEqual(run.steps.map(\.state.word), ["Done", "Failed", "Blocked", "Done", "Done"])
        XCTAssertNil(run.steps[2].answer?.result?.extraWord, "Blocked is the row's word; it is not said twice")
        XCTAssertNil(run.steps[1].reason)
    }

    func testACheckThatJudgedFailDoesNotStopTheRun() throws {
        let run = try run()
        XCTAssertEqual(run.stoppedAt?.stepID, "review")
        XCTAssertEqual(run.whereText, "ended after Review")
        XCTAssertFalse(run.steps[1].stopsTheRun)
        XCTAssertTrue(RunStep(id: "b", stepID: "b", title: "Build", state: .failed).stopsTheRun, "a step that failed to run still stops it")
        XCTAssertTrue(RunStep(id: "q", stepID: "q", title: "Ask", state: .paused).stopsTheRun)
        XCTAssertFalse(RunStep(id: "k", stepID: "k", title: "Check", state: .blocked).stopsTheRun)
    }

    func testTheTimelineReadsAJudgedCheckAsFailed() throws {
        let events = try history().events
        let result = { (id: String) in TicketEventsPayload.eventResult(try XCTUnwrap(events.first { $0.id == id })) }
        XCTAssertEqual(try result("s2"), .failed)
        XCTAssertEqual(try result("s3"), .failed, "blocked reads as a blocked verdict does")
        XCTAssertEqual(try result("s4"), .done)
        XCTAssertEqual(try result("s1"), .done, "a step without a result keeps its outcome")
    }

    func testAStepWithoutAJudgementKeepsItsOutcome() {
        let payload = { (json: String) in TicketEventsPayload.decode(Data(json.utf8))!.events[0].payload }
        func page(_ fields: String) -> String {
            #"{"timeline":[{"id":"e1","at":"2026-11-20T10:00:00Z","type":"step.completed","run_id":"r","payload":{\#(fields)},"artifacts":[],"children":[]}]}"#
        }
        XCTAssertEqual(RunGroupModel.completion(payload(page(#""outcome":"passed""#))).0, .done)
        XCTAssertEqual(RunGroupModel.completion(payload(page(#""outcome":"passed","result":{"status":"plan_mismatch"}"#))).0, .done)
        XCTAssertEqual(RunGroupModel.completion(payload(page(#""outcome":"failed","returns_to":"code""#))).0, .failed)
        XCTAssertEqual(RunGroupModel.completion(payload(page(#""outcome":"skipped","result":{"status":"fail"}"#))).0, .skipped)
        XCTAssertEqual(RunGroupModel.completion(payload(page(#""outcome":"passed","result":{"status":"Blocked"}"#))).0, .blocked)
    }

    func testAJudgementIsTheStatusAsAStepState() {
        let judgement = { (status: String?) in StepAnswer.Result(status: status, expected: nil, actual: nil).judgement }
        XCTAssertEqual(judgement("pass"), .done)
        XCTAssertEqual(judgement("fail"), .failed)
        XCTAssertEqual(judgement("blocked"), .blocked)
        XCTAssertNil(judgement("plan_mismatch"))
        XCTAssertNil(judgement(nil))
        XCTAssertEqual(StepAnswer.Result(status: "plan_mismatch", expected: nil, actual: nil).extraWord, "plan_mismatch")
    }

    func testABlockedStepHasItsOwnWordMarkAndTint() {
        let blocked = RunStep.State.blocked
        XCTAssertEqual(blocked.word, "Blocked")
        XCTAssertEqual(blocked.status, .problem)
        XCTAssertEqual(blocked.symbol, "exclamationmark.circle.fill")
        XCTAssertEqual(blocked.markSymbol, "exclamationmark")
    }

    // MARK: - The Conductor's message under it

    func testAnOldStepsBlockDrawsTheWordsTheStepsDraw() throws {
        let steps = try stepsBlock("u1", in: history())
        XCTAssertEqual(steps.steps.map(\.outcome), [.passed, .failed, .blocked, .passed, .passed])
    }

    func testANewStepsBlockKeepsItsWords() throws {
        let steps = try stepsBlock("u2", in: history())
        XCTAssertEqual(steps.steps.map(\.outcome), [.failed, .blocked, .passed])
    }

    func testAStepsBlockThatDoesNotMatchItsRunIsLeftAsWritten() throws {
        // Five steps in the block and four step events before it: nothing to match them by, so it stays as written.
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: Self.fixture)) as? [String: Any])
        var timeline = try XCTUnwrap(json["timeline"] as? [[String: Any]])
        var run = timeline[0]
        run["events"] = try XCTUnwrap(run["events"] as? [[String: Any]]).filter { $0["id"] as? String != "s1" }
        timeline[0] = run
        json["timeline"] = timeline
        let history = try XCTUnwrap(TicketEventsPayload.decode(JSONSerialization.data(withJSONObject: json)))
        XCTAssertEqual(try stepsBlock("u1", in: history).steps.map(\.outcome), [.passed, .passed, .passed, .passed, .passed])
    }

    func testAPageThatArrivesLaterSettlesTheBlocksItBrings() throws {
        let data = try Data(contentsOf: Self.fixture)
        var held = try XCTUnwrap(TicketEventsPayload.decode(data))
        held.events.removeAll { $0.type == "conductor.update" }
        let newer = #"{"timeline":[{"id":"u3","seq":200,"at":"2026-11-20T11:00:00Z","type":"conductor.update","payload":{"text":"Again.","blocks":[{"type":"steps","run_id":"qa-2","steps":[{"step_id":"walk_1","title":"Walk step 1","outcome":"passed"},{"step_id":"design_check","title":"Design check","outcome":"passed"},{"step_id":"wide_pass","title":"Wide pass","outcome":"passed"},{"step_id":"review","title":"Review","outcome":"passed"}]}]},"artifacts":[],"children":[]}]}"#
        held.merge(try XCTUnwrap(TicketEventsPayload.decode(Data(newer.utf8))))
        let steps = try stepsBlock("u3", in: held)
        XCTAssertEqual(steps.steps.map(\.outcome), [.failed, .blocked, .passed, .passed])
    }

    func testABlockedStepReadsFromTheFeed() throws {
        let page = #"{"timeline":[{"id":"u1","at":"2026-11-20T09:00:00Z","type":"conductor.update","payload":{"text":"Words.","blocks":[{"type":"steps","steps":[{"step_id":"d","title":"Design check","outcome":"blocked"}]}]},"artifacts":[],"children":[]}]}"#
        let steps = try stepsBlock("u1", in: XCTUnwrap(TicketEventsPayload.decode(Data(page.utf8))))
        XCTAssertEqual(steps.steps.first?.outcome, .blocked)
    }
}
