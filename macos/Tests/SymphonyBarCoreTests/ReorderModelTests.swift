import XCTest
@testable import SymphonyBarCore

/// TP-1531: the Reorderable list's order. A line is picked up, moved to any place and dropped, which reports the new
/// order once; Escape puts it back; the only line is never removed.
final class ReorderModelTests: XCTestCase {
    private let lines = ["opus", "kimi", "deepseek"]

    // MARK: - The walkthrough

    /// Step 1: the third line dragged above the first lands at the top, and the numbers follow on the drop.
    func testDraggingTheThirdLineAboveTheFirstMovesItToTheTop() {
        var model = ReorderModel(lines)
        XCTAssertTrue(model.pickUp("deepseek"))
        let target = ReorderModel<String>.target(from: 2, translation: -80, pitch: 34, count: 3)
        XCTAssertEqual(target, 0, "two and a bit lines up is above the first")
        XCTAssertTrue(model.move(to: target))
        XCTAssertEqual(model.number(of: "deepseek"), 3, "while it is up the numbers keep their places")
        XCTAssertEqual(model.drop(), ["deepseek", "opus", "kimi"])
        XCTAssertEqual([model.number(of: "deepseek"), model.number(of: "opus"), model.number(of: "kimi")], [1, 2, 3])
        XCTAssertNil(model.lifted)
    }

    /// Step 2: Space, Up twice, Space moves the line up two places, reported once, on the drop.
    func testSpaceUpTwiceSpaceMovesTheLineUpTwoPlaces() {
        var model = ReorderModel(lines)
        model.pickUp("deepseek")
        XCTAssertTrue(model.move(by: -1))
        XCTAssertTrue(model.move(by: -1))
        XCTAssertEqual(model.order, ["deepseek", "opus", "kimi"])
        XCTAssertEqual(model.drop(), ["deepseek", "opus", "kimi"])
        XCTAssertNil(model.drop(), "a second drop reports nothing")
    }

    /// Step 3: Space, Down, Escape puts the line back where it started and reports nothing.
    func testEscapePutsTheLineBackWhereItStarted() {
        var model = ReorderModel(lines)
        model.pickUp("opus")
        model.move(by: 1)
        XCTAssertEqual(model.order, ["kimi", "opus", "deepseek"])
        model.cancel()
        XCTAssertEqual(model.order, lines)
        XCTAssertNil(model.lifted)
        XCTAssertNil(model.drop(), "nothing is up, so nothing is reported")
    }

    // MARK: - Dropping

    func testDropAtTheEnd() {
        var model = ReorderModel(lines)
        model.pickUp("opus")
        XCTAssertTrue(model.move(to: 9), "past the end is held to the last place")
        XCTAssertEqual(model.drop(), ["kimi", "deepseek", "opus"])
    }

    func testDropAboveTheFirst() {
        var model = ReorderModel(lines)
        model.pickUp("kimi")
        XCTAssertTrue(model.move(to: -3), "above the first is the first place")
        XCTAssertEqual(model.drop(), ["kimi", "opus", "deepseek"])
    }

    func testADropWhereTheLineStartedReportsNothing() {
        var model = ReorderModel(lines)
        model.pickUp("kimi")
        model.move(by: 1)
        model.move(by: -1)
        XCTAssertNil(model.drop())
        XCTAssertEqual(model.order, lines)
    }

    func testTheArrowsStopAtEitherEnd() {
        var model = ReorderModel(lines)
        model.pickUp("opus")
        XCTAssertFalse(model.move(by: -1), "Up on the first line does nothing")
        model.move(by: 2)
        XCTAssertFalse(model.move(by: 1), "Down on the last line does nothing")
        XCTAssertEqual(model.order.last, "opus")
    }

    func testOnlyOneLineIsUpAtATime() {
        var model = ReorderModel(lines)
        XCTAssertFalse(model.move(by: 1), "nothing moves while nothing is up")
        XCTAssertFalse(model.move(to: 2))
        XCTAssertFalse(model.pickUp("gpt"), "a line that is not in the list")
        XCTAssertTrue(model.pickUp("opus"))
        XCTAssertFalse(model.pickUp("kimi"))
        XCTAssertEqual(model.lifted, "opus")
        model.cancel()
        model.cancel()
        XCTAssertNil(model.lifted)
    }

    // MARK: - Removing

    func testTheOnlyLineIsNeverRemoved() {
        let model = ReorderModel(["opus"])
        XCTAssertFalse(model.canRemove("opus"))
        XCTAssertFalse(model.showsRemove, "the only line has no remove button")
    }

    func testALineIsRemovedOnlyWhileNothingIsUp() {
        var model = ReorderModel(lines)
        XCTAssertTrue(model.showsRemove)
        XCTAssertTrue(model.canRemove("kimi"))
        XCTAssertFalse(model.canRemove("gpt"))
        model.pickUp("opus")
        XCTAssertFalse(model.canRemove("kimi"))
    }

    func testTheCallersOrderIsTakenOnlyWhileNothingIsUp() {
        var model = ReorderModel(lines)
        model.reset(["opus", "kimi"])
        XCTAssertEqual(model.order, ["opus", "kimi"])
        model.pickUp("kimi")
        model.reset(["opus"])
        XCTAssertEqual(model.order, ["opus", "kimi"], "the lift goes on")
        XCTAssertEqual(model.position(of: "kimi"), 2)
        XCTAssertNil(model.position(of: "gpt"))
        XCTAssertNil(model.number(of: "gpt"))
    }

    // MARK: - The pointer

    func testTheTargetRoundsThePlacesThePointerTravelled() {
        XCTAssertEqual(ReorderModel<String>.target(from: 0, translation: 16, pitch: 34, count: 3), 0)
        XCTAssertEqual(ReorderModel<String>.target(from: 0, translation: 18, pitch: 34, count: 3), 1)
        XCTAssertEqual(ReorderModel<String>.target(from: 0, translation: 500, pitch: 34, count: 3), 2)
        XCTAssertEqual(ReorderModel<String>.target(from: 1, translation: -500, pitch: 34, count: 3), 0)
        XCTAssertEqual(ReorderModel<String>.target(from: 1, translation: 100, pitch: 0, count: 3), 1, "no pitch, no move")
    }

    func testTheLinesBetweenStepAside() {
        // Dragged down from 0 to 2: lines 1 and 2 step up.
        XCTAssertEqual((0..<3).map { ReorderModel<String>.shift($0, from: 0, to: 2) }, [0, -1, -1])
        // Dragged up from 2 to 0: lines 0 and 1 step down.
        XCTAssertEqual((0..<3).map { ReorderModel<String>.shift($0, from: 2, to: 0) }, [1, 1, 0])
        XCTAssertEqual((0..<3).map { ReorderModel<String>.shift($0, from: 1, to: 1) }, [0, 0, 0])
    }

    func testThePitchIsALineAndItsGap() {
        XCTAssertEqual(DesignTokens.ReorderableList.pitch(28), 34)
        XCTAssertEqual(DesignTokens.ReorderableList.pitch(10), 34, "a line is at least 28 pt")
        XCTAssertEqual(DesignTokens.ReorderableList.pitch(40), 46)
    }

    // MARK: - VoiceOver

    func testWhatVoiceOverSays() {
        XCTAssertEqual(ReorderSpeech.handle(2), "Move line 2")
        XCTAssertEqual(ReorderSpeech.pickedUp(2, of: 3), "Picked up. Line 2 of 3")
        XCTAssertEqual(ReorderSpeech.moved(1, of: 3), "Line 1 of 3")
        XCTAssertEqual(ReorderSpeech.dropped(1, of: 3), "Dropped. Line 1 of 3")
        XCTAssertEqual(ReorderSpeech.putBack(2, of: 3), "Put back. Line 2 of 3")
    }
}
