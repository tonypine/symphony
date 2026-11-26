import SwiftUI
import SymphonyBarCore
import XCTest
@testable import SymphonyBarUI

/// How a run's group draws the way it ended (TP-1689): a run without steps keeps its conversation once it ended, a
/// review that sent the work back wears the Sent back badge, and Blocked is the idle grey with a struck circle.
final class RunEndTests: XCTestCase {
    func testTheSentBackBadgeDrawsTheReturnArrowInAmber() {
        let state = RunGroupModel.State.sentBack
        let badge = Badge(status: state.status, word: RunGroupModel.requestChanges, symbol: state.badgeSymbol)
        XCTAssertEqual(badge.symbol, "arrow.uturn.backward")
        XCTAssertEqual(badge.word, "Request changes")
        XCTAssertEqual(state.status, .you)
        // A state with no glyph of its own keeps its status's, and a badge without a glyph draws none.
        XCTAssertEqual(Badge(status: .done, word: "Approved", symbol: RunGroupModel.State.passed.badgeSymbol).symbol, DesignTokens.Status.done.symbol)
        XCTAssertNil(Badge(status: .you, word: "Request changes", glyph: false, symbol: "arrow.uturn.backward").symbol)
    }

    func testTheBlockedBadgeDrawsAStruckCircleInTheIdleGrey() {
        let state = RunGroupModel.State.blocked
        let badge = Badge(status: state.status, word: "Blocked", symbol: state.badgeSymbol)
        XCTAssertEqual(badge.symbol, "circle.slash")
        XCTAssertEqual(state.status, .idle)
    }

    /// A saved conversation says where it stands in its owner's words while it has no lines, and draws its lines
    /// otherwise; no note ever says a run recorded no steps.
    func testASavedConversationsNotesSpeakOfItsOwnerAndNeverOfNoSteps() {
        let line = TranscriptLine(kind: .say, text: "Done.")
        for notes in [SavedConversation.Notes.run, .step] {
            XCTAssertNil(notes.text(.loaded([line])))
            XCTAssertEqual(notes.text(.loaded([])), notes.empty)
            XCTAssertEqual(notes.text(.loading), notes.loading)
            XCTAssertEqual(notes.text(.unavailable), notes.unavailable)
            XCTAssertEqual(notes.text(.failed), notes.failed)
            for text in [notes.loading, notes.empty, notes.unavailable, notes.failed] {
                XCTAssertFalse(text.contains("recorded no steps"), text)
            }
        }
        XCTAssertEqual(SavedConversation.Notes.run.loading, "Reading what happened in this run…")
        XCTAssertEqual(SavedConversation.Notes.step.loading, "Reading what happened in this step…")
    }
}
