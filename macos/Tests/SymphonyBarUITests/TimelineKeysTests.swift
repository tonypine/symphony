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

    func testEachEntrySaysWhatItsGlyphMeansAndItsToneIsItsClasssColour() {
        XCTAssertEqual(TimelineEntryRow.glyphHelp(.phase), "Phase move")
        XCTAssertEqual(TimelineEntryRow.glyphHelp(.questionAsked), "Question asked")
        XCTAssertEqual(TimelineEntryRow.color(.accent), DesignTokens.ColorToken.accent.color)
        XCTAssertEqual(TimelineEntryRow.color(.status(.problem)), DesignTokens.Status.problem.tint)
        XCTAssertEqual(TimelineSection.maxWidth, 780)
    }
}
