@testable import SymphonyBarCore
import XCTest

/// What the Conductor cost: its own segment on the Lifecycle token bar, counted once in the ticket's total, and its run's
/// tokens, model and duration on the timeline like any run's.
final class ConductorTokensTests: XCTestCase {
    private func lifecycle(coding: Int, qa: Int, total: Int, cap: Int? = nil) -> TicketLifecycle {
        TicketLifecycle(
            current: "coding",
            stages: [
                .init(id: "coding", name: "Coding", state: .current, tokens: coding), .init(id: "code_review", name: "Code Review", state: .notYet),
                .init(id: "qa", name: "QA", state: .notYet, tokens: qa), .init(id: "merging", name: "Merging", state: .notYet),
            ],
            tokens: .init(total: total, cap: cap)
        )
    }

    func testTheConductorHasASegmentOfItsOwnWhenItHasTokens() {
        let bar = LifecycleModel.build(lifecycle(coding: 2_000_000, qa: 1_000_000, total: 3_400_000, cap: 8_000_000), conductorTokens: 400_000).tokens
        let conductor = bar.segments.last
        XCTAssertEqual(conductor?.id, "conductor")
        XCTAssertEqual(conductor?.name, "Conductor")
        XCTAssertEqual(conductor?.tokens, 400_000)
        XCTAssertEqual(conductor?.value, "400K")
        XCTAssertEqual(conductor?.isConductor, true)
        XCTAssertNil(conductor?.series, "drawn in the accent, not a chart series")
        XCTAssertEqual(bar.segments.filter { !$0.isConductor }.map(\.id), ["coding", "code_review", "qa", "merging"])
        XCTAssertEqual(bar.total, 3_400_000, "counted in the total once")
        XCTAssertEqual(bar.value, "3.4M of 8M tokens · 42 %")
        XCTAssertTrue(bar.accessibilityLabel.contains("Conductor 400K"))
    }

    func testNoTokensNoSegment() {
        let bar = LifecycleModel.build(lifecycle(coding: 2_000_000, qa: 1_000_000, total: 3_000_000), conductorTokens: 0).tokens
        XCTAssertFalse(bar.segments.contains { $0.isConductor })
        XCTAssertEqual(bar.segments.count, 4)
    }

    func testASymphonyThatStillCountsTheConductorInItsStageGetsNoSecondSegment() {
        // The stages already add up to the total: the Conductor's 400K are in Coding, and a segment would count them twice.
        let bar = LifecycleModel.build(lifecycle(coding: 2_400_000, qa: 1_000_000, total: 3_400_000), conductorTokens: 400_000).tokens
        XCTAssertFalse(bar.segments.contains { $0.isConductor })
        XCTAssertEqual(bar.total, 3_400_000)
    }

    func testTheConductorsRunsOnTheHistoryAreSummed() throws {
        let history = try XCTUnwrap(TicketEventsPayload.decode(Data(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/timeline/conductor-watch.json"))))
        XCTAssertEqual(history.conductorTokens, 18_000, "run-c1's run.ended; run-2 is not the Conductor's")
        XCTAssertEqual(TicketEventsPayload().conductorTokens, 0)
    }

    func testAConductorRunShowsItsModelDurationAndTokensLikeAnyRun() throws {
        let history = try XCTUnwrap(TicketEventsPayload.decode(Data(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/timeline/conductor.json"))))
        let run = try XCTUnwrap(RunGroupModel.groups(history, reference: Date()).first { $0.id == "run-c1" })
        XCTAssertEqual(run.tokensText, "18K tokens")
        XCTAssertEqual(run.meta, "Claude Opus 5.5 · 1 min · 18K tokens")
    }

    func testAConductorRunThatRecordedNoTokensShowsNone() throws {
        let page = #"{"timeline":[{"kind":"run","run_id":"c1","run_kind":"conductor","run_number":1,"status":"ended","started_at":"2026-10-08T09:00:00Z","events":[{"id":"e1","at":"2026-10-08T09:01:00Z","type":"run.ended","run_id":"c1","payload":{"exit":"ended","duration_ms":60000,"tokens":0},"artifacts":[],"children":[]}]}]}"#
        let history = try XCTUnwrap(TicketEventsPayload.decode(Data(page.utf8)))
        XCTAssertEqual(history.conductorTokens, 0)
        XCTAssertNil(try XCTUnwrap(RunGroupModel.groups(history, reference: Date()).first).tokensText)
    }
}
