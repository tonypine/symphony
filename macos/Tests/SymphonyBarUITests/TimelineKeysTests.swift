import SwiftUI
import SymphonyBarCore
import XCTest
@testable import SymphonyBarUI

/// The timeline's keys (§4 Keyboard): the arrows move the selection, Return and Space fold the selected run, Escape
/// clears the selection.
final class TimelineKeysTests: XCTestCase {
    func testTheArrowsMoveTheSelectionReturnAndSpaceFoldAndEscapeClears() {
        XCTAssertEqual(TimelineKeys.action(.downArrow, modifiers: []), .move(1))
        XCTAssertEqual(TimelineKeys.action(.upArrow, modifiers: []), .move(-1))
        XCTAssertEqual(TimelineKeys.action(.return, modifiers: []), .toggle)
        XCTAssertEqual(TimelineKeys.action(.space, modifiers: []), .toggle)
        XCTAssertEqual(TimelineKeys.action(.escape, modifiers: []), .clear)
        // The arrows come with the numeric pad and function flags, the keypad's Enter with the numeric pad's.
        XCTAssertEqual(TimelineKeys.action(.downArrow, modifiers: [.numericPad, .function]), .move(1))
        XCTAssertEqual(TimelineKeys.action(.return, modifiers: .numericPad), .toggle)
    }

    func testAnotherKeyOrAModifierDoesNothing() {
        XCTAssertNil(TimelineKeys.action(.tab, modifiers: []))
        XCTAssertNil(TimelineKeys.action(KeyEquivalent("j"), modifiers: []))
        XCTAssertNil(TimelineKeys.action(.downArrow, modifiers: .command))
        XCTAssertNil(TimelineKeys.action(.return, modifiers: .shift))
        XCTAssertEqual(TimelineKeys.keys, [.upArrow, .downArrow, .return, .space, .escape])
    }

    /// TP-1572: a click on an entry or a run, through the closure the timeline gives the row it draws, takes the
    /// keyboard and leaves nothing selected, whatever the arrows selected before: no row carries the accent tint and
    /// ring after a click, so there is nothing to dismiss with Escape.
    @MainActor
    func testAClickLeavesNoRowSelectedAndSoNoOutline() {
        let entry = TimelineItem.entry(TimelineEntry(id: "a1", kind: .phase, at: .now, title: "Moved to Todo", actor: "Tony"))
        let run = TimelineItem.run(RunGroupModel(id: "r1", title: "Implementation run 1", state: .failed, word: "Failed", steps: []), at: .now)
        let transcripts = StepTranscripts { _ in .unreachable }
        func row(_ item: TimelineItem, selection: String?, click: TimelineClick) -> TimelineRow {
            TimelineSection.makeRow(
                item, selection: selection, connects: false, clock: { _ in "09:00" }, transcripts: transcripts,
                fold: { _ in .constant(true) }, click: click
            )
        }
        func selected(_ row: TimelineRow) -> Bool {
            switch row {
            case let .entry(row): row.selected
            case let .run(row): row.selected
            }
        }
        for item in [entry, run] {
            for before in [nil, item.id, "entry-other"] {
                var selection = before
                var keyboard = false
                let click = TimelineClick(takeKeyboard: { keyboard = true }) { selection = $0 }
                XCTAssertEqual(selected(row(item, selection: before, click: click)), before == item.id, "the arrows' selection draws")

                row(item, selection: before, click: click).click()

                XCTAssertTrue(keyboard, "\(item.id): the click gives the timeline the keyboard")
                XCTAssertNil(selection, "\(item.id) clicked with \(before ?? "nothing") selected")
                let after = row(item, selection: selection, click: click)
                XCTAssertFalse(selected(after))
                XCTAssertFalse(DesignTokens.Interaction(hovered: true, selected: selected(after)).showsSelectionRing)
            }
        }
    }

    func testEachEntrySaysWhatItsGlyphMeansAndItsToneIsItsClasssColour() {
        XCTAssertEqual(TimelineEntryRow.glyphHelp(.phase), "Phase move")
        XCTAssertEqual(TimelineEntryRow.glyphHelp(.questionAsked), "Question asked")
        XCTAssertEqual(TimelineEntryRow.color(.accent), DesignTokens.ColorToken.accent.color)
        XCTAssertEqual(TimelineEntryRow.color(.status(.problem)), DesignTokens.Status.problem.tint)
        XCTAssertEqual(TimelineSection.maxWidth, 780)
    }
}
