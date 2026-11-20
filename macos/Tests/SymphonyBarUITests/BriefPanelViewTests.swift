import AppKit
import SwiftUI
import XCTest
@testable import SymphonyBarCore
@testable import SymphonyBarUI

/// TP-1504: the brief as the page draws it. Its code and paths are in the mono face, the prose in the reading style's
/// own; folded it is three lines tall, unfolded taller; "Asked for" has no fold.
@MainActor
final class BriefPanelViewTests: XCTestCase {
    private func fittingSize(_ view: some View) -> CGSize {
        let host = NSHostingView(rootView: view.environment(\.offscreenSnapshot, true))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }

    private let brief = BriefPanelModel(
        kind: .brief, title: "Brief", note: "written by Implementation run 2 at 11:20",
        text: String(repeating: "The ticket page opens with the brief, in large reading text at the top of the column. ", count: 12),
        walkthrough: "Open a ticket.", asked: "## Problem\n\nThe brief is buried."
    )

    func testCodeRunsAreMonoAndProseKeepsTheStylesFont() {
        let text = ReadingText.attributed("Open docs/index.html now.")
        typealias FontKey = AttributeScopes.SwiftUIAttributes.FontAttribute
        let runs = Array(text.runs)
        XCTAssertEqual(runs.count, 3)
        XCTAssertNil(runs[0][FontKey.self])
        XCTAssertNotNil(runs[1][FontKey.self])
        XCTAssertEqual(String(text[runs[1].range].characters), "docs/index.html")
        XCTAssertNil(runs[2][FontKey.self])
    }

    func testTheFoldedBriefIsShorterThanTheUnfoldedOne() {
        let folded = fittingSize(BriefPanel(model: brief, open: .constant(false)).frame(width: 780))
        let unfolded = fittingSize(BriefPanel(model: brief, open: .constant(true)).frame(width: 780))
        XCTAssertGreaterThan(unfolded.height, folded.height)
        // "Asked for" has no fold: open or not, it draws the same.
        let asked = BriefPanelModel(kind: .askedFor, title: "Asked for", note: "no run has written a brief yet", text: brief.text)
        XCTAssertEqual(
            fittingSize(BriefPanel(model: asked, open: .constant(false)).frame(width: 780)).height,
            fittingSize(BriefPanel(model: asked, open: .constant(true)).frame(width: 780)).height, accuracy: 0.5
        )
    }

    func testTheDecisionsPanelComparesItsModel() {
        let one = DecisionsPanelModel.build([TicketDecision(id: "D1", answer: "Keep it")])
        XCTAssertEqual(DecisionsPanel(model: one), DecisionsPanel(model: one))
        XCTAssertEqual(DecisionRow(row: one.rows[0]).row.byline, "You")
    }
}
