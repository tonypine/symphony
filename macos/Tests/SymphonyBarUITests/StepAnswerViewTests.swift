import AppKit
import SwiftUI
import XCTest
@testable import SymphonyBarCore
@testable import SymphonyBarUI

/// What an unfolded QA step shows above its lines.
@MainActor
final class StepAnswerViewTests: XCTestCase {
    private func size(_ view: some View, width: CGFloat = 700) -> CGSize {
        let host = NSHostingView(rootView: view.frame(width: width))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }

    private func answer(_ answer: StepAnswer) -> StepAnswerView { StepAnswerView(answer: answer) }

    func testAResultDrawsExpectedAndActualBesideEachOtherWithTheirOwnLabels() {
        XCTAssertEqual(ExpectedAndActual.expectedLabel, "Expected")
        XCTAssertEqual(ExpectedAndActual.stepActualLabel, "Actual")
        let side = size(answer(StepAnswer(result: .init(status: "failed", expected: "A row", actual: "No row"))))
        let stacked = size(answer(StepAnswer(result: .init(status: "failed", expected: "A row", actual: "No row"))), width: 300)
        XCTAssertGreaterThan(stacked.height, side.height * 1.5)
    }

    func testALongPaneIsCutAtTwelveLinesWithShowMore() {
        let long = (1...40).map { "Line \($0) of what QA saw" }.joined(separator: "\n")
        let short = size(answer(StepAnswer(result: .init(status: "failed", expected: "x", actual: long))))
        let whole = size(ExpectedAndActual(expected: "x", actual: long))
        XCTAssertLessThan(short.height, whole.height, "the 40 lines are cut")
        XCTAssertEqual(StepAnswerView.resultLines, 12)
        XCTAssertEqual(ClampedText.showMore, "Show more")
    }

    func testAPlanDrawsAListOnlyWhenItHasItems() {
        let plan = StepAnswer.Plan(summary: "Three checks.", checks: [.init(title: "A", expect: "a")], skips: [])
        let full = StepAnswer.Plan(summary: "Three checks.", checks: [.init(title: "A", expect: "a")], skips: [.init(title: "B", why: "Not here")])
        XCTAssertGreaterThan(size(answer(StepAnswer(plan: full))).height, size(answer(StepAnswer(plan: plan))).height + 20)
        let summaryOnly = StepAnswer.Plan(summary: "Three checks.", checks: [], skips: [])
        XCTAssertLessThan(size(answer(StepAnswer(plan: summaryOnly))).height, size(answer(StepAnswer(plan: plan))).height)
    }

    func testARecheckDrawsOneGroupAnItem() {
        let one = StepAnswer.Recheck(title: "Row", instructions: ["Open", "Read"], expect: "A mark", design: nil)
        let two = size(answer(StepAnswer(rechecks: [one, one])))
        XCTAssertEqual(two.height, size(answer(StepAnswer(rechecks: [one]))).height * 2 + 12, accuracy: 24)
    }

    func testAGroupedWalkDrawsEachChecksExpectedAndActualAndOneLinePerCheck() {
        let one = StepAnswer.CheckResult(step: 1, result: .init(status: "pass", expected: "A", actual: "A"))
        let two = StepAnswer.CheckResult(step: 2, result: .init(status: "fail", expected: "B", actual: "C"))
        let bare = StepAnswer.CheckResult(step: 3, result: .init(status: "blocked"))
        XCTAssertGreaterThan(size(answer(StepAnswer(results: [one, two]))).height, size(answer(StepAnswer(results: [one]))).height + 20)
        XCTAssertEqual(size(answer(StepAnswer(results: [one, bare]))).height, size(answer(StepAnswer(results: [one]))).height, accuracy: 1)

        let rows = size(CheckResultRows(results: [one, two, bare]))
        XCTAssertGreaterThan(rows.height, size(CheckResultRows(results: [one])).height * 2.5)
        XCTAssertEqual(CheckResultRows.accessibilityLabel, "Checks of the step")
    }

    func testAStepsRowSaysItsResultsStatusWhenItAddsInformation() {
        var step = RunStep(id: "c", stepID: "c", title: "Check", state: .failed)
        step.answer = StepAnswer(result: .init(status: "plan_mismatch", expected: "x", actual: "y"))
        XCTAssertTrue(step.canUnfold)
        XCTAssertEqual(step.answer?.result?.extraWord, "plan_mismatch")
    }

    func testAnAnswersEntriesAreKeyValueRowsWithValuesCutAtEightLines() {
        let long = (1...30).map { "line \($0)" }.joined(separator: "\n")
        let cut = size(StepAnswerView(answer: StepAnswer(entries: [.init(label: "Files", value: long)])))
        let whole = size(KeyValueList(style: .secondary) { KeyValueRow("Files", text: long) })
        XCTAssertLessThan(cut.height, whole.height)
        XCTAssertEqual(StepAnswerView.valueLines, 8)
        let three = size(StepAnswerView(answer: StepAnswer(entries: [.init(label: "A", value: "1"), .init(label: "B", value: "2"), .init(label: "C", value: "3")])))
        XCTAssertGreaterThan(three.height, size(StepAnswerView(answer: StepAnswer(entries: [.init(label: "A", value: "1")]))).height)
    }

    func testAFailedStepsLongReasonIsShownWholeWhenOpened() {
        let reason = (1...5).map { "Reason line \($0)" }.joined(separator: "\n")
        XCTAssertGreaterThan(size(StepAnswerView(reason: reason)).height, size(StepAnswerView(reason: "One line")).height * 3)
    }
}
