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

    func testFourTilesForThePeriod() throws {
        let quality = try self.quality(.month)
        XCTAssertEqual(quality.tiles.map(\.title), ["Review agreement", "QA passed first time", "Runs that opened a PR", "PRs sent to Rework"])
        XCTAssertEqual(quality.tiles[0].value, "92%")
        XCTAssertEqual(quality.tiles[0].context, "12 judged Code Review approvals")
        XCTAssertEqual(quality.tiles[1].value, "82%")
        XCTAssertEqual(quality.tiles[3].value, "23%")
        XCTAssertEqual(quality.runs.count, 44)
        let opened = quality.runs.filter { $0.outcome == .prOpened }.count
        XCTAssertEqual(quality.tiles[2].value, Quality.percent(Double(opened) / 44))
    }

    func testAShorterPeriodKeepsItsDaysAndRuns() throws {
        let month = try quality(.month)
        let week = try quality(.week)
        XCTAssertEqual(month.dates.count, 14)
        XCTAssertEqual(week.dates.count, 7)
        XCTAssertEqual(week.runs.map(\.date).min(), "2026-10-01")
        XCTAssertLessThan(week.runs.count, month.runs.count)
        XCTAssertEqual(Quality.Period.allCases.map(\.title), ["Last 7 days", "Last 30 days", "Last 90 days"])
        XCTAssertEqual(Quality.Period.week.id, 7)
    }

    func testAgreementByRepoNamesTheManualReview() throws {
        let quality = try quality(.month)
        XCTAssertEqual(quality.repos.map(\.mode), ["Manual review off", "Manual review on"])
        XCTAssertEqual(quality.repos.map(\.value), ["5 of 5 upheld", "6 of 7 upheld"])
        XCTAssertEqual(quality.agreementTable.first, ["Repo", "Mode", "Agreement", "Upheld"])
        XCTAssertEqual(quality.agreementTable[2], ["shop", "Manual review on", "86%", "6 of 7 upheld"])
        XCTAssertEqual(quality.agreementSummary, "api: 100%, 5 of 5 upheld, Manual review off. shop: 86%, 6 of 7 upheld, Manual review on.")
    }

    func testDisagreementsShowBothDecisions() throws {
        XCTAssertEqual(try quality(.month).disagreements, [
            Quality.DisagreementRow(identifier: "SHOP-298", repoKey: "shop", review: "Code Review: Approved", decision: "Director: Sent to Rework"),
        ])
    }

    func testRunsByOutcomeUseStatusColorsNeverSeries() throws {
        let quality = try quality(.month)
        XCTAssertEqual(quality.outcomes, [.prOpened, .noChanges, .error])
        XCTAssertEqual(QualityRun.Outcome.allCases.map(\.status), [.done, .idle, .problem])
        let last = try XCTUnwrap(quality.dates.last)
        XCTAssertEqual(quality.hoverLine(on: last), "Oct 7: Opened a PR 4, Failed 2; 6 runs")
        XCTAssertEqual(quality.outcomesTable.first, ["Day", "Opened a PR", "No changes", "Failed", "Total"])
        XCTAssertEqual(quality.outcomesTable.count, 15)
        XCTAssertTrue(quality.outcomesSummary.hasPrefix("44 runs over 14 days: "))
    }

    func testShowAllRunsFiltersByAgentOutcomeAndDay() throws {
        let quality = try quality(.month)
        let failed = quality.runs(matching: Quality.RunFilter(outcome: .error))
        XCTAssertFalse(failed.isEmpty)
        XCTAssertTrue(failed.allSatisfy { $0.outcome == .error })
        XCTAssertEqual(quality.agents, ["claude", "codex"])
        XCTAssertEqual(quality.runDates.first, "2026-10-07")
        let one = quality.runs(matching: Quality.RunFilter(agent: "codex", date: "2026-09-24"))
        XCTAssertTrue(one.allSatisfy { $0.agent == "codex" && $0.date == "2026-09-24" })
        XCTAssertEqual(quality.runs(matching: Quality.RunFilter()).count, quality.runs.count)
    }

    func testAnEmptyPeriodSaysSo() {
        let quality = Quality(history: HistoryPayload(days: 7), runs: [], period: .week)
        XCTAssertEqual(quality.tiles.map(\.value), ["—", "—", "—", "—"])
        XCTAssertTrue(quality.tiles.allSatisfy(\.isEmpty))
        XCTAssertEqual(quality.tiles[0].context, "Nothing to count yet")
        XCTAssertEqual(quality.outcomesSummary, "No runs in the last 0 days.")
        XCTAssertEqual(quality.agreementSummary, "No Code Review approval in the last 0 days.")
        XCTAssertEqual(quality.hoverLine(on: Date(timeIntervalSince1970: 0)), "Jan 1: no runs")
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

    private func quality(_ period: Quality.Period) throws -> Quality {
        Quality(history: try history(), runs: try runs(), period: period)
    }
}
