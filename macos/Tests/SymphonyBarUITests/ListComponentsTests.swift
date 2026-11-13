import AppKit
import SwiftUI
import XCTest
@testable import SymphonyBarCore
@testable import SymphonyBarUI

/// TP-1507: the catalog's Row, tree and progress strip as the app draws them.
@MainActor
final class ListComponentsTests: XCTestCase {
    private func fittingSize(_ view: some View, width: CGFloat = 640) -> CGSize {
        let host = NSHostingView(rootView: view.frame(width: width))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }

    // MARK: - Row

    func testARowIsThirtyFourPointsOnOneLineAndFiftyTwoOnTwo() {
        XCTAssertEqual(fittingSize(Row("Checkout total rounding", identifier: "SHOP-305", lead: .status(.working), value: "14 min")).height, 34, accuracy: 0.5)
        XCTAssertEqual(
            fittingSize(Row("Checkout total rounding", identifier: "SHOP-305", lead: .dot(.working, live: true), line2: "Waiting for CI", value: "6 min")).height,
            52, accuracy: 0.5
        )
        // A badge and a small button in the trail keep it one line high.
        let trailed = Row("Proration", identifier: "BIL-306", lead: .status(.you), value: "3 h") {
            Badge(status: .you, word: "Question", size: .small)
            Button("Answer") {}.directorButton(.primary, size: .small)
        }
        XCTAssertEqual(fittingSize(trailed).height, 34, accuracy: 0.5)
    }

    func testALongTitleIsCutAndTheRowKeepsItsWidth() {
        let long = String(repeating: "A ticket with a very long title ", count: 10)
        XCTAssertEqual(fittingSize(Row(long, identifier: "TP-1", value: "1 min"), width: 400), CGSize(width: 400, height: 34))
    }

    func testTheValueColumnIsAtLeastItsWidthSoTrailsAlign() {
        // A short value and a longer one take the same column, so the rows' trails line up.
        func column(_ value: String) -> CGFloat {
            let host = NSHostingView(rootView: RowValue(value).frame(minWidth: DesignTokens.Row.valueWidth, alignment: .trailing))
            host.layoutSubtreeIfNeeded()
            return host.fittingSize.width
        }
        XCTAssertEqual(column("1 min"), DesignTokens.Row.valueWidth)
        XCTAssertEqual(column("14 min"), DesignTokens.Row.valueWidth)
    }

    func testARowWithAnActionShowsItsStatesAndOneWithoutDoesNot() {
        let still = Row("Version", value: "1.2.3")
        XCTAssertFalse(still.acts)
        XCTAssertEqual(still.shown, .rest)
        let selected = Row("Saved carts", identifier: "SHOP-301", selected: true, select: {})
        XCTAssertTrue(selected.acts)
        XCTAssertTrue(selected.shown.selected)
        XCTAssertFalse(Row("Saved carts", selected: true, focused: true).shown.disabled)
        XCTAssertTrue(Row("Saved carts", focused: true).shown.focused)
        XCTAssertEqual(Row("Saved carts", state: .hover).shown, .hover)
        XCTAssertTrue(Row("Saved carts", line2: "Waiting for CI").twoLines)
    }

    func testASelectedRowsWordsTurnWhiteAtEightyFivePercent() {
        XCTAssertEqual(Row<EmptyView>.secondaryColor(onAccent: false), DesignTokens.TextColor.secondary.color)
        XCTAssertEqual(
            Row<EmptyView>.secondaryColor(onAccent: true),
            DesignTokens.TextColor.onAccent.color.opacity(DesignTokens.Row.onAccentSecondary)
        )
    }

    // MARK: - Tree list

    func testATreeDrawsEachChildOneStepInUnderItsParent() {
        let nodes = [TreeNode("A", children: [TreeNode("B", children: [TreeNode("C")])])]
        let tree = TreeList(nodes, foldDepth: nil, opened: .constant([]), selection: .constant(nil)) { id, _ in
            Row(id, identifier: id)
        }
        .environment(\.offscreenSnapshot, true)
        // Three one-line rows, 2 pt apart (and 2 pt after the last).
        XCTAssertEqual(fittingSize(tree).height, 3 * (34 + DesignTokens.Tree.lineGap), accuracy: 0.5)
    }

    func testAFoldedChainDrawsItsPillOnAOneLineRow() {
        let nodes = [TreeNode("A", children: [TreeNode("B", children: [TreeNode("C", children: [TreeNode("D"), TreeNode("E")])])])]
        let tree = TreeList(nodes, opened: .constant([]), selection: .constant(nil)) { id, _ in Row(id) }
            .environment(\.offscreenSnapshot, true)
        // A, B and C, then the pill for D and E.
        XCTAssertEqual(fittingSize(tree).height, 4 * (34 + DesignTokens.Tree.lineGap), accuracy: 0.5)
        let opened = TreeList(nodes, opened: .constant(["A"]), selection: .constant(nil)) { id, _ in Row(id) }
            .environment(\.offscreenSnapshot, true)
        XCTAssertEqual(fittingSize(opened).height, 5 * (34 + DesignTokens.Tree.lineGap), accuracy: 0.5)
    }

    // MARK: - Progress strip

    func testAStripFillsItsWidthAtItsHeight() {
        let items: [DesignTokens.ProgressStrip.Item] = [.init(.done), .init(.working, live: true), .init(nil)]
        XCTAssertEqual(fittingSize(ProgressStrip(items), width: 132), CGSize(width: 132, height: 5))
        XCTAssertEqual(fittingSize(ProgressStrip(items, height: DesignTokens.ProgressStrip.headerHeight), width: 720).height, 6)
    }

    func testAStripsLabelStatesItsCounts() {
        let items: [DesignTokens.ProgressStrip.Item] = [.init(.done), .init(.done), .init(.working, live: true), .init(nil)]
        XCTAssertEqual(ProgressStrip.accessibilityLabel(items, label: "2 of 4 sub-tickets done"), "2 of 4 sub-tickets done: 2 done, 1 working, 1 waiting")
        XCTAssertEqual(ProgressStrip.accessibilityLabel(items, label: nil), "2 done, 1 working, 1 waiting")
    }

    func testTheWorkedOnSegmentBreathesUnlessReduceMotionOrASnapshot() {
        XCTAssertTrue(ProgressStrip.breathes(live: true, reduceMotion: false, offscreen: false))
        XCTAssertFalse(ProgressStrip.breathes(live: true, reduceMotion: true, offscreen: false))
        XCTAssertFalse(ProgressStrip.breathes(live: true, reduceMotion: false, offscreen: true))
        XCTAssertFalse(ProgressStrip.breathes(live: false, reduceMotion: false, offscreen: false))
    }

    /// The catalog's `.epic-strip i.live { animation: ds-breathe 1.8s var(--ease-standard) infinite }` with
    /// `@keyframes ds-breathe { 50% { opacity: 0.45 } }`, run by Core Animation: no frame of it is drawn by the app.
    func testAWorkingSegmentBreathesAsTheCatalogDrawsItOnCoreAnimation() throws {
        let breath = try XCTUnwrap(
            LayerPulse.animation(ProgressStrip.breath, duration: DesignTokens.ProgressStrip.breathePeriod) as? CAKeyframeAnimation
        )
        XCTAssertEqual(breath.keyPath, "opacity")
        XCTAssertEqual(breath.values as? [Double], [1, 0.45, 1])
        XCTAssertEqual(breath.keyTimes, [0, 0.5, 1])
        XCTAssertEqual(breath.duration, 1.8)
        XCTAssertEqual(breath.repeatCount, .infinity)
        XCTAssertFalse(breath.autoreverses)
        XCTAssertFalse(breath.isRemovedOnCompletion)
        let halves = try XCTUnwrap(breath.timingFunctions)
        XCTAssertEqual(halves.count, 2)
        for half in halves {
            var first: [Float] = [0, 0]
            var second: [Float] = [0, 0]
            half.getControlPoint(at: 1, values: &first)
            half.getControlPoint(at: 2, values: &second)
            XCTAssertEqual(first + second, [0.2, 0, 0, 1])
        }
        // A segment breathes only while its item is worked on, in a window, with motion allowed.
        XCTAssertTrue(ProgressStrip.breathes(live: true, reduceMotion: false, offscreen: false))
        XCTAssertFalse(ProgressStrip.breathes(live: false, reduceMotion: false, offscreen: false))
        XCTAssertFalse(ProgressStrip.breathes(live: true, reduceMotion: true, offscreen: false))
        XCTAssertFalse(ProgressStrip.breathes(live: true, reduceMotion: false, offscreen: true))
    }
}
