import XCTest
@testable import SymphonyBarCore

final class QualityTests: XCTestCase {
    func testDecodesTheShippedReviewHistory() throws {
        let review = try XCTUnwrap(try history().review)
        XCTAssertEqual(review.agreement, ReviewHistory.Agreement(agreed: 11, disagreed: 1, pending: 1))
        XCTAssertEqual(review.byRepo.map(\.repoKey), ["api", "shop"])
        XCTAssertEqual(review.byRepo.map(\.manualReview), [.off, .on])
        XCTAssertEqual(review.disagreements, [ReviewHistory.Disagreement(identifier: "SHOP-298", repoKey: "shop", decision: "Sent to Rework", decidedBy: "Director")])
        XCTAssertEqual(review.qaFirstPass.passed, 9)
        XCTAssertEqual(review.sentToRework.reviewed, 13)
    }

    func testAHistoryWithoutReviewDecodesWithNone() throws {
        let payload = try XCTUnwrap(HistoryPayload.decode(Data(#"{"days": 1}"#.utf8)))
        XCTAssertNil(payload.review)
        let partial = try XCTUnwrap(HistoryPayload.decode(Data(#"""
            {"days": 1, "review": {"by_repo": [{"repo_key": "a", "manual_review": "maybe"}, {"agreed": 1}],
             "disagreements": [{"issue_id": "i-1", "decision": "QA failed"}, {"identifier": "X-1"}]}}
            """#.utf8)))
        let review = try XCTUnwrap(partial.review)
        XCTAssertEqual(review.byRepo, [ReviewHistory.Repo(repoKey: "a", manualReview: .off, agreement: ReviewHistory.Agreement())])
        XCTAssertEqual(review.disagreements, [ReviewHistory.Disagreement(identifier: "i-1", decision: "QA failed", decidedBy: "QA")])
        XCTAssertNil(review.agreement.rate)
        XCTAssertNotEqual(review, ReviewHistory())
    }

    func testDecodesTheShippedRuns() throws {
        let runs = try self.runs()
        XCTAssertEqual(runs.count, 3 + 41)
        XCTAssertEqual(runs.first?.identifier, "SHOP-288")
        XCTAssertEqual(runs.first?.tokens, 980_000)
        XCTAssertNil(QualityRun.decode(Data("nope".utf8)))
        XCTAssertEqual(QualityRun.decode(Data(#"{"runs": [{"outcome": "error"}, {"date": "2026-10-07"}]}"#.utf8)), [
            QualityRun(id: "run-1", outcome: .noChanges, date: "2026-10-07"),
        ])
        XCTAssertEqual(QualityRun.path(from: "2026-09-24"), "api/v1/runs?date_from=2026-09-24&limit=500")
    }

    func testFourTilesForTheSlice() throws {
        let quality = try self.quality()
        XCTAssertEqual(quality.tiles.map(\.title), ["Runs that succeeded", "Code Review approvals", "QA passes", "Review agreement"])
        XCTAssertEqual(quality.tiles[0].value, "84%")
        XCTAssertEqual(quality.tiles[0].context, "50 runs")
        XCTAssertEqual(quality.tiles[1].value, "90%")
        XCTAssertEqual(quality.tiles[1].context, "21 Code Review verdicts")
        XCTAssertEqual(quality.tiles[2].value, "82%")
        XCTAssertEqual(quality.tiles[3].value, "92%")
        XCTAssertEqual(quality.tiles[3].context, "12 judged Code Review approvals")
        XCTAssertNil(quality.empty)
    }

    func testTheSlicesRepoKeepsItsAgreementAndDisagreements() throws {
        let shop = try quality(InsightsSlice(repo: "shop"))
        XCTAssertEqual(shop.repos.map(\.repoKey), ["shop"])
        XCTAssertEqual(shop.tiles[3].value, "86%")
        XCTAssertEqual(shop.disagreements.map(\.identifier), ["SHOP-298"])
        let api = try quality(InsightsSlice(), scope: .repo("api"))
        XCTAssertEqual(api.repos.map(\.repoKey), ["api"])
        XCTAssertTrue(api.disagreements.isEmpty)
        let gone = try quality(InsightsSlice(repo: "gone"))
        XCTAssertEqual(gone.tiles[3].value, "—")
    }

    func testAgreementByRepoNamesTheManualReview() throws {
        let quality = try quality()
        XCTAssertEqual(quality.repos.map(\.mode), ["Manual review off", "Manual review on"])
        XCTAssertEqual(quality.repos.map(\.value), ["5 of 5 upheld", "6 of 7 upheld"])
        XCTAssertEqual(quality.agreementTable.first, ["Repo", "Mode", "Agreement", "Upheld"])
        XCTAssertEqual(quality.agreementTable[2], ["shop", "Manual review on", "86%", "6 of 7 upheld"])
        XCTAssertEqual(quality.agreementSummary, "api: 100%, 5 of 5 upheld, Manual review off. shop: 86%, 6 of 7 upheld, Manual review on.")
    }

    func testDisagreementsShowBothDecisions() throws {
        XCTAssertEqual(try quality().disagreements, [
            Quality.DisagreementRow(identifier: "SHOP-298", repoKey: "shop", review: "Code Review: Approved", decision: "Director: Sent to Rework"),
        ])
    }

    func testRunsAndVerdictsUseStatusColorsNeverSeries() throws {
        let quality = try quality()
        XCTAssertEqual(quality.runsChart.title, "Runs per day")
        XCTAssertEqual(quality.runsChart.keys.map(\.name), ["Succeeded", "Failed", "Timed out", "Stopped"])
        XCTAssertEqual(quality.runsChart.keys.map(\.tint), [.status(.done), .status(.problem), .status(.you), .status(.idle)])
        XCTAssertEqual(quality.runsChart.total, 50)
        let last = try XCTUnwrap(quality.runsChart.bars.last)
        XCTAssertEqual(quality.runsChart.hoverLine(last.id), "Nov 12: Succeeded 3")
        XCTAssertEqual(quality.verdictsChart.keys.map(\.name), ["Approved or passed", "Sent back or failed"])
        XCTAssertEqual(quality.verdictsChart.total, 38)
        XCTAssertEqual(Quality.runKey("cancelled").key, "stopped")
        XCTAssertEqual(Quality.runKey("mystery").name, "Other")
        XCTAssertEqual(Quality.verdictKey("code_review:block").key, "returned")
        XCTAssertEqual(Quality.verdictKey("plan:odd").key, "other")
        XCTAssertEqual(QualityRun.Outcome.allCases.map(\.status), [.done, .idle, .problem])
    }

    func testShowAllRunsKeepsTheSlicesDaysAndFiltersByAgentOutcomeAndDay() throws {
        let quality = try quality()
        XCTAssertEqual(quality.runs.count, 50)
        XCTAssertEqual(quality.runs.map(\.date).min(), "2026-11-06")
        let failed = quality.runs(matching: Quality.RunFilter(outcome: .error))
        XCTAssertFalse(failed.isEmpty)
        XCTAssertTrue(failed.allSatisfy { $0.outcome == .error })
        XCTAssertEqual(quality.agents, ["claude", "codex"])
        XCTAssertEqual(quality.runDates.first, "2026-11-12")
        let one = quality.runs(matching: Quality.RunFilter(agent: "codex", date: "2026-11-07"))
        XCTAssertTrue(one.allSatisfy { $0.agent == "codex" && $0.date == "2026-11-07" })
        XCTAssertEqual(quality.runs(matching: Quality.RunFilter()).count, quality.runs.count)
        XCTAssertEqual(try self.quality(InsightsSlice(period: .preset(.today))).runs.count, 3)
    }

    func testAnEmptySliceSaysSo() {
        let quality = Quality(aggregate: AggregatePayload(), slice: InsightsSlice(), review: nil, runs: [], today: "2026-11-12")
        XCTAssertEqual(quality.tiles.map(\.value), ["—", "—", "—", "—"])
        XCTAssertTrue(quality.tiles.allSatisfy(\.isEmpty))
        XCTAssertEqual(quality.tiles[0].context, "Nothing to count yet")
        XCTAssertEqual(quality.agreementSummary, "No Code Review approval in this period.")
        XCTAssertEqual(quality.empty?.title, "No runs or verdicts in the last 7 days.")
    }

    private func fixture(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/director-app/attention/api/v1/\(name)")
        return try Data(contentsOf: url)
    }

    private func history() throws -> HistoryPayload {
        try XCTUnwrap(HistoryPayload.decode(fixture("history.json")))
    }

    private func runs() throws -> [QualityRun] {
        try XCTUnwrap(QualityRun.decode(fixture("runs.json")))
    }

    /// The `insights` fixture's slice with the `attention` fixture's review.
    private func quality(_ slice: InsightsSlice = InsightsSlice(), scope: OverviewScope = .all) throws -> Quality {
        let api = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/director-app/insights/api/v1")
        let aggregate = try XCTUnwrap(AggregatePayload.decode(Data(contentsOf: api.appendingPathComponent("aggregate.json"))))
        let runs = try XCTUnwrap(QualityRun.decode(Data(contentsOf: api.appendingPathComponent("runs.json"))))
        return Quality(aggregate: aggregate, slice: slice, scope: scope, review: try history().review, runs: runs, today: "2026-11-12")
    }
}
