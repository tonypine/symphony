import AppKit
import SwiftUI
import XCTest
@testable import SymphonyBarCore
@testable import SymphonyBarUI

/// The Conductor's block components: the run path stays on one line whatever its width, the panes stack when narrow,
/// references become chips, and the parts built from existing components read their data as the block gives it.
@MainActor
final class ConductorBlockViewsTests: XCTestCase {
    private func blocks(_ json: String) -> [ConductorBlock] { ConductorBlock.read(json: json) }

    private func height(_ view: some View, width: CGFloat) -> CGFloat {
        let host = NSHostingView(rootView: view.frame(width: width))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    private let longPath = #"[{"type":"path","loops":0,"stops":[{"phase":"Backlog","state":"done"},{"phase":"A very long phase name indeed","state":"failed","times":3},{"phase":"Another quite long phase name","state":"current","run_number":12},{"phase":"A third phase with a long name","state":"upcoming"},{"phase":"Merge","state":"upcoming"}]}]"#

    func testTheRunPathIsOneLineAtAnyWidth() throws {
        guard case let .path(path)? = blocks(longPath).first else { return XCTFail() }
        let wide = height(RunPath(path: path), width: 900)
        for width in [500, 300, 160] as [CGFloat] {
            XCTAssertEqual(height(RunPath(path: path), width: width), wide, accuracy: 1, "one line at \(width) pt, names cut rather than wrapped")
        }
    }

    func testAnEqualPairOfPanesStacksWhenNarrow() throws {
        guard case let .compare(compare)? = blocks(#"[{"type":"compare","expected":{"text":"Needs a fix"},"actual":{"text":"Next in line"}}]"#).first else { return XCTFail() }
        let sideBySide = height(ExpectedAndActual(compare: compare), width: 620)
        let stacked = height(ExpectedAndActual(compare: compare), width: 300)
        XCTAssertGreaterThan(stacked, sideBySide * 1.6)
        XCTAssertEqual(ExpectedAndActual.expectedLabel, "Expected")
        XCTAssertEqual(ExpectedAndActual.actualLabel, "QA saw")
    }

    func testAnAttemptsLabelReadsEveryTryAndTheRepeat() throws {
        guard case let .attempts(attempts)? = blocks(#"[{"type":"attempts","step_id":"b","title":"Build","same_line":true,"tries":[{"outcome":"failed","line":"a:1 error"},{"outcome":"failed","line":"a:1 error"}]}]"#).first else { return XCTFail() }
        XCTAssertEqual(AttemptsList.accessibilityLabel(attempts), "Attempts at Build: failed, a:1 error; failed, a:1 error. Same error every time")
    }

    func testTheStepsBlockIsTheRunGroupsOwnRowsAndReadsItsOutcomes() throws {
        guard case let .steps(steps)? = blocks(#"[{"type":"steps","steps":[{"step_id":"c","title":"Code","outcome":"passed","duration_ms":120000},{"step_id":"b","title":"Build","outcome":"failed","returns_to":"Code"}]}]"#).first else { return XCTFail() }
        let rows = StepsBlockView.runSteps(steps)
        XCTAssertEqual(rows.map(\.state), [.done, .failed])
        XCTAssertEqual(rows[0].duration, "2 min")
        XCTAssertEqual(rows[1].reason, "back to Code")
        XCTAssertFalse(rows[0].canUnfold, "not expandable here")
    }

    func testTheBudgetNamesKindsOfRunsAndFormatsTokensAsTheRunHeaderDoes() {
        XCTAssertEqual(BudgetBlockView.label(.init(kind: "qa", runs: 2, tokens: 26_000_000)), "QA, 2 runs")
        XCTAssertEqual(BudgetBlockView.label(.init(kind: "code_review", runs: 1, tokens: 0)), "Code review, 1 run")
        XCTAssertEqual(BudgetBlockView.label(.init(kind: "conductor", runs: 0, tokens: 0)), "Conductor")
        XCTAssertEqual(Overview.tokens(21_000_000), "21M")
    }

    func testAnEpicRowsStateGivesItsMark() {
        XCTAssertEqual(EpicBlockView.status("done"), .done)
        XCTAssertEqual(EpicBlockView.status("in_review"), .working)
        XCTAssertEqual(EpicBlockView.status("needs_a_fix"), .problem)
        XCTAssertEqual(EpicBlockView.status("queued"), .idle)
        XCTAssertEqual(EpicBlockView.words("in_review"), "In review")
        XCTAssertEqual(EpicBlockView.label(.init(identifier: "TP-1", title: "T", state: "done", current: true)), "TP-1, T, Done, this ticket")
    }

    func testAQuestionNotOpenSaysWhatBecameOfIt() {
        var context = ConductorQuestionContext(decisions: [TicketDecision(id: "d1", answer: "Stop and send back")])
        XCTAssertEqual(context.outcome("d1"), "Answered: Stop and send back")
        XCTAssertEqual(context.outcome("d2"), "No longer open")
        XCTAssertNil(context.open("d1"))
        context.questions = [InboxReview.Action(title: nil, question: "Q?", why: nil, unblocks: nil, steps: [], options: [], commentID: "d1", confirm: nil)]
        XCTAssertEqual(context.open("d1")?.index, 0)
    }

    func testAReferenceSpanBecomesAChipAndTheWordsAroundItFlow() {
        let phrases = ConductorMarkup.phrases(in: "It is `#969` for `TP-1500`, and `plain`.")
        XCTAssertTrue(ConductorMarkup.hasReference(phrases))
        let fragments = ConductorReferenceParagraph.fragments(phrases, style: .reading, bold: false)
        XCTAssertEqual(fragments.compactMap { if case let .reference(key) = $0 { key } else { nil } }, ["#969", "TP-1500"])
        XCTAssertGreaterThan(fragments.count, 5, "the words are cut after each space")
        XCTAssertFalse(ConductorMarkup.hasReference(ConductorMarkup.phrases(in: "`plain` and `run make`")))
    }

    func testTheMessageHoldsItsBlocksBeforeItsClosingNextParagraph() {
        let message = ConductorMessage(
            id: "m", at: nil, text: "Headline.\n\nNext: QA.", blocks: blocks(#"[{"type":"findings","items":[{"title":"One","state":"open"}]}]"#)
        )
        let with = height(ConductorMarkupText(markup: message.markup, blocks: message.blocks), width: 640)
        let without = height(ConductorMarkupText(markup: message.markup), width: 640)
        XCTAssertGreaterThan(with, without + 20)
    }
}
