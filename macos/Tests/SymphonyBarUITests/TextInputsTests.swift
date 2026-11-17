import AppKit
import SwiftUI
import XCTest
@testable import SymphonyBarCore
@testable import SymphonyBarUI

/// TP-1509: the shared Text field, Search field and Text area. Their inputs are the control heights; the area grows
/// with its text between its fewest and most lines, then scrolls; Escape in a search field clears, then lets go.
@MainActor
final class TextInputsTests: XCTestCase {
    private func fittingSize(_ view: some View) -> CGSize {
        let host = NSHostingView(rootView: view.frame(width: 300))
        host.layout()
        return host.fittingSize
    }

    func testTheTextAndSearchFieldsAreTheControlHeights() {
        for size in DesignTokens.Control.allCases {
            let field = DirectorTextField(nil, text: .constant(""), placeholder: "Deploy freeze", size: size, drawnAs: .rest)
            XCTAssertEqual(fittingSize(field).height, size.height, accuracy: 0.5, "\(size)")
            let live = DirectorTextField(nil, text: .constant("Deploy freeze"), size: size)
            XCTAssertEqual(fittingSize(live).height, size.height, accuracy: 0.5, "a live \(size) field")
            let search = SearchField("Search tickets", text: .constant(""), size: size, drawnAs: .rest)
            XCTAssertEqual(fittingSize(search).height, size.height, accuracy: 0.5, "\(size)")
            let query = SearchField("Search tickets", text: .constant("catalog"), matches: 3, size: size)
            XCTAssertEqual(fittingSize(query).height, size.height, accuracy: 0.5, "a \(size) field with a query")
        }
    }

    func testTheLabelAndOneLineUnderItAddToTheField() {
        let bare = fittingSize(DirectorTextField(nil, text: .constant(""), drawnAs: .rest)).height
        let labelled = fittingSize(DirectorTextField("Reason", text: .constant(""), drawnAs: .rest)).height
        let helped = fittingSize(DirectorTextField("Reason", text: .constant(""), help: "Shown to everyone.", drawnAs: .rest)).height
        let both = fittingSize(
            DirectorTextField("Reason", text: .constant(""), help: "Shown to everyone.", error: "Give a reason.", drawnAs: .focused)
        ).height
        XCTAssertGreaterThan(labelled, bare)
        XCTAssertGreaterThan(helped, labelled)
        XCTAssertEqual(both, helped, accuracy: 0.5, "the error takes the help's place, never both")
    }

    func testTheNoMatchLineShowsOnlyWithAQueryThatFoundNothing() {
        let searched = "Search looks at identifiers and titles."
        let found = fittingSize(SearchField("Search tickets", text: .constant("catalog"), matches: 3, searched: searched)).height
        let none = fittingSize(SearchField("Search tickets", text: .constant("storybook"), matches: 0, searched: searched)).height
        let empty = fittingSize(SearchField("Search tickets", text: .constant(""), matches: 0, searched: searched)).height
        XCTAssertEqual(found, DesignTokens.Control.medium.height, accuracy: 0.5)
        XCTAssertEqual(empty, DesignTokens.Control.medium.height, accuracy: 0.5)
        XCTAssertGreaterThan(none, found + CGFloat(DesignTokens.Field.gap))
    }

    func testTheAreaGrowsWithItsTextBetweenItsFewestAndMostLines() {
        func height(_ text: String, minLines: Int = 3, maxLines: Int = 8) -> CGFloat {
            fittingSize(TextArea("Answer", text: .constant(text), minLines: minLines, maxLines: maxLines, drawnAs: .rest)).height
        }
        let lines = { (count: Int) in (1...count).map { "Line \($0)" }.joined(separator: "\n") }
        let padding = CGFloat(2 * DesignTokens.Field.areaVerticalPadding)
        XCTAssertEqual(height(""), TextArea.lineHeight * 3 + padding, accuracy: 0.5, "it starts three lines tall")
        XCTAssertEqual(height(lines(2)), height(""), accuracy: 0.5, "two lines fit in three")
        XCTAssertGreaterThan(height(lines(5)), height(""), "it grows as lines are added")
        XCTAssertGreaterThan(height(lines(8)), height(lines(5)))
        XCTAssertEqual(height(lines(20)), height(lines(8)), accuracy: 0.5, "past eight lines it scrolls")
        XCTAssertGreaterThanOrEqual(height("", minLines: 1, maxLines: 6), TextArea.lineHeight + padding - 0.5, "one line at least")
        XCTAssertLessThan(height("", minLines: 1, maxLines: 6), height(""), "fewer lines start shorter")
        XCTAssertEqual(height(lines(9), minLines: 1, maxLines: 6), height(lines(6), minLines: 1, maxLines: 6), accuracy: 0.5)
    }

    func testTheAreaKeepsItsLimitsInOrder() {
        let area = TextArea("Answer", text: .constant(""), minLines: 0, maxLines: -2)
        XCTAssertEqual(area.minLines, 1)
        XCTAssertEqual(area.maxLines, 1)
        let live = fittingSize(TextArea("Answer", text: .constant("One"), minLines: 2, maxLines: 4)).height
        XCTAssertEqual(live, TextArea.lineHeight * 2 + CGFloat(2 * DesignTokens.Field.areaVerticalPadding), accuracy: 0.5, "a live area sizes as a still one")
    }

    func testTheOwnWordsFieldIsAnAccentedTextArea() {
        struct Host: View {
            @FocusState var focused: Bool
            var body: some View { WriteInField(initialText: "Leave them to TP-891.", commit: { _ in }, focused: $focused) }
        }
        let height = fittingSize(Host()).height
        XCTAssertGreaterThan(height, TextArea.lineHeight * 3 + CGFloat(2 * DesignTokens.Field.areaVerticalPadding), "the area and its hint")
    }

    func testEscapeIsTakenOnlyWhileTheWatcherRuns() {
        let watcher = EscapeWatcher()
        var steps: [DesignTokens.Field.EscapeStep] = []
        var query = "storybook"
        watcher.perform = {
            let step = DesignTokens.Field.escape(query: query)
            steps.append(step)
            if step == .clear { query = "" }
            return true
        }
        XCTAssertTrue(watcher.perform())
        XCTAssertTrue(watcher.perform())
        XCTAssertEqual(steps, [.clear, .release], "Escape clears, then lets go")
        watcher.start()
        watcher.start()
        watcher.stop()
        watcher.stop()
        XCTAssertEqual(EscapeWatcher.escapeKeyCode, 53)
    }

    /// The monitor sees every key of the app: an Escape not in this field's window, or with the keyboard in another
    /// field, is left to whoever owns it (a sheet's own search field, its Cancel).
    func testEscapeIsTakenOnlyInTheFieldThatHasTheKeyboard() {
        let window = NSObject(), sheet = NSObject()
        let field = CGRect(x: 20, y: 400, width: 240, height: 28)
        let editorInField = CGRect(x: 44, y: 404, width: 180, height: 20)
        let editorElsewhere = CGRect(x: 20, y: 100, width: 240, height: 20)
        XCTAssertTrue(EscapeWatcher.belongs(eventWindow: window, fieldWindow: window, editorFrame: editorInField, fieldFrame: field))
        XCTAssertFalse(EscapeWatcher.belongs(eventWindow: sheet, fieldWindow: window, editorFrame: editorInField, fieldFrame: field),
                       "an Escape in a sheet over the window")
        XCTAssertFalse(EscapeWatcher.belongs(eventWindow: nil, fieldWindow: window, editorFrame: editorInField, fieldFrame: field))
        XCTAssertFalse(EscapeWatcher.belongs(eventWindow: window, fieldWindow: nil, editorFrame: editorInField, fieldFrame: field),
                       "a field not in a window yet")
        XCTAssertFalse(EscapeWatcher.belongs(eventWindow: window, fieldWindow: window, editorFrame: editorElsewhere, fieldFrame: field),
                       "the keyboard is in another field of the window")
        XCTAssertFalse(EscapeWatcher.belongs(eventWindow: window, fieldWindow: window, editorFrame: nil, fieldFrame: field),
                       "nothing is typing")
        XCTAssertFalse(EscapeWatcher.belongs(eventWindow: window, fieldWindow: window, editorFrame: editorInField, fieldFrame: .null))

        XCTAssertTrue(EscapeWatcher.isPlainEscape(keyCode: 53, modifiers: []))
        XCTAssertTrue(EscapeWatcher.isPlainEscape(keyCode: 53, modifiers: .capsLock))
        XCTAssertFalse(EscapeWatcher.isPlainEscape(keyCode: 53, modifiers: .command))
        XCTAssertFalse(EscapeWatcher.isPlainEscape(keyCode: 36, modifiers: []))
    }

    /// An Escape from a window that is not the field's (here none) reaches `take` and is not taken.
    func testAnEscapeFromAnotherWindowIsNotTaken() throws {
        let watcher = EscapeWatcher()
        var performed = 0
        watcher.perform = { performed += 1; return true }
        let anchor = NSView(frame: CGRect(x: 0, y: 0, width: 240, height: 28))
        watcher.anchor = anchor
        let escape = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: EscapeWatcher.escapeKeyCode
        ))
        XCTAssertFalse(watcher.take(escape))
        let other = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0
        ))
        XCTAssertFalse(watcher.take(other))
        XCTAssertEqual(performed, 0)
    }

    /// A field in the window's toolbar is out of reach of a page's focus state: its anchor finds the window's text
    /// field that sits inside the field, and says the field has the keyboard when the window's editor is inside it.
    func testTheAnchorFindsTheTextFieldInsideTheSearchField() {
        let field = CGRect(x: 900, y: 860, width: 220, height: 24)
        let finder = CGRect(x: 300, y: 400, width: 400, height: 22)
        let inside = CGRect(x: 924, y: 862, width: 150, height: 20)
        XCTAssertEqual(FieldAnchorView.pick([finder, inside], fieldFrame: field), 1)
        XCTAssertNil(FieldAnchorView.pick([finder], fieldFrame: field), "no text field inside the search field")
        XCTAssertNil(FieldAnchorView.pick([inside], fieldFrame: .null), "the field is not in a window yet")
        XCTAssertTrue(FieldAnchorView.inField(inside, fieldFrame: field))
        XCTAssertFalse(FieldAnchorView.inField(.null, fieldFrame: field))
    }

    /// Before the field is in a window, a request for the keyboard waits; nothing is editing and nothing lets go.
    func testAnAnchorOutsideAWindowHoldsTheRequest() {
        let anchor = FieldAnchorView()
        var reports: [Bool] = []
        anchor.editing = { reports.append($0) }
        XCTAssertFalse(anchor.isEditing)
        anchor.focusField()
        anchor.release()
        anchor.viewDidMoveToWindow()
        XCTAssertEqual(reports, [], "no window, no first responder to report")
    }

    /// The area shows no scroll bar while its text fits its most lines; past them, it scrolls.
    func testTheTextAreaScrollsOnlyPastItsMostLines() {
        let line = TextArea.lineHeight
        XCTAssertFalse(TextArea.overflows(height: line * 3, maxLines: 6))
        XCTAssertFalse(TextArea.overflows(height: line * 6, maxLines: 6), "at its maximum it still fits")
        XCTAssertTrue(TextArea.overflows(height: line * 7, maxLines: 6))
    }
}
