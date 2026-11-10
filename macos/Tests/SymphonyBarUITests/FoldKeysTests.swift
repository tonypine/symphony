import SwiftUI
import SymphonyBarCore
import XCTest
@testable import SymphonyBarUI

/// Return and Space toggle the fold that has the keyboard: a run group's or a step's header (§4 Keyboard).
final class FoldKeysTests: XCTestCase {
    func testReturnAndSpaceToggleAFocusedFold() {
        XCTAssertTrue(FoldKeys.toggles(.return, modifiers: []))
        XCTAssertTrue(FoldKeys.toggles(.space, modifiers: []))
        // The keypad's Enter comes with the numeric pad flag.
        XCTAssertTrue(FoldKeys.toggles(.return, modifiers: .numericPad))
    }

    func testAnotherKeyOrAModifierLeavesTheFoldAsItIs() {
        XCTAssertFalse(FoldKeys.toggles(.tab, modifiers: []))
        XCTAssertFalse(FoldKeys.toggles(KeyEquivalent("a"), modifiers: []))
        XCTAssertFalse(FoldKeys.toggles(.return, modifiers: .command))
        XCTAssertFalse(FoldKeys.toggles(.space, modifiers: .shift))
    }

    func testALineKeepsItsKeyAsTheRunNowsWindowOfLinesSlides() {
        let said = TranscriptLine(kind: .say, text: "Running the tests", at: "2026-10-07T12:00:00Z")
        let called = TranscriptLine(kind: .tool, text: "Bash: mix test", at: "2026-10-07T12:00:01Z")
        let before = LineList.keyed([said, called, called]).map(\.key)
        let after = LineList.keyed([called, called, said]).map(\.key)
        XCTAssertEqual(Set(before), Set(after))
        XCTAssertEqual(Set(before).count, 3)
        XCTAssertEqual(before[2], before[1] + "#2")
    }

    func testALineSaysWhenItHappenedAndWhatItsGlyphMeans() {
        let zone = NSTimeZone.default
        NSTimeZone.default = TimeZone(identifier: "UTC")!
        defer { NSTimeZone.default = zone }
        XCTAssertEqual(TranscriptLineRow.clock(Date(timeIntervalSince1970: 3_725)), "01:02:05")
        XCTAssertEqual(TranscriptLineRow.glyphHelp(TranscriptLine(kind: .say, text: "x")), "The agent said")
        XCTAssertEqual(TranscriptLineRow.glyphHelp(TranscriptLine(kind: .tool, text: "x")), "A tool call")
        XCTAssertEqual(TranscriptLineRow.glyphHelp(TranscriptLine(kind: .result, text: "x")), "What it returned")
        XCTAssertEqual(TranscriptLineRow.glyphHelp(TranscriptLine(kind: .result, text: "x", failed: true)), "What it returned: the tool failed")
    }
}
