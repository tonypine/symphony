import AppKit
import SwiftUI
import SymphonyBarCore
import XCTest
@testable import SymphonyBarUI

/// The Control bar (TP-1497): what narrows the page at the left, what acts on it at the right, and the summary under
/// the controls on a laptop, beside them on a desktop.
@MainActor
final class ControlBarTests: XCTestCase {
    /// An AppKit view placed in the bar, so the test reads where the bar put it.
    private struct Marker: NSViewRepresentable {
        let view: NSView

        func makeNSView(context _: Context) -> NSView { view }
        func updateNSView(_: NSView, context _: Context) {}
    }

    /// The frames of the markers in a bar `width` wide, in the host's coordinates measured from its top-left.
    private func frames(width: CGFloat, @ViewBuilder bar: (Marker, Marker) -> some View) -> (CGRect, CGRect, CGSize) {
        let first = NSView()
        let second = NSView()
        let host = NSHostingView(rootView: bar(Marker(view: first), Marker(view: second)).environment(\.offscreenSnapshot, true))
        let height = host.fittingSize.height
        host.frame = CGRect(x: 0, y: 0, width: width, height: height)
        host.layoutSubtreeIfNeeded()
        func flipped(_ view: NSView) -> CGRect {
            let frame = view.convert(view.bounds, to: host)
            return host.isFlipped ? frame : CGRect(x: frame.minX, y: host.bounds.height - frame.maxY, width: frame.width, height: frame.height)
        }
        return (flipped(first), flipped(second), host.bounds.size)
    }

    func testWhatNarrowsIsAtTheLeftAndWhatActsAtTheRight() {
        let (narrow, act, size) = frames(width: 1000) { left, right in
            ControlBar("Page controls") {
                left.frame(width: 80, height: 24)
            } act: {
                right.frame(width: 60, height: 24)
            }
        }
        let bar = DesignTokens.ControlBar.self
        XCTAssertEqual(narrow.minX, bar.pageInset + bar.horizontalPadding, accuracy: 0.5)
        XCTAssertEqual(act.maxX, size.width - bar.pageInset - bar.horizontalPadding, accuracy: 0.5)
        XCTAssertEqual(narrow.midY, act.midY, accuracy: 0.5, "both sides on one line")
    }

    func testOnALaptopTheSummaryHasItsOwnLineUnderTheControls() {
        XCTAssertFalse(ControlBarLayout.beside(width: 1100, controls: CGSize(width: 300, height: 24), summary: CGSize(width: 200, height: 16)))
    }

    func testOnADesktopTheSummarySitsBesideTheControlsWhenTheLineHoldsBoth() {
        XCTAssertTrue(ControlBarLayout.beside(width: 1800, controls: CGSize(width: 900, height: 24), summary: CGSize(width: 300, height: 16)))
        XCTAssertFalse(
            ControlBarLayout.beside(width: 1800, controls: CGSize(width: 1600, height: 24), summary: CGSize(width: 300, height: 16)),
            "a line that can't hold both puts the summary under"
        )
    }

    func testTheBarIsTallerWithItsSummaryUnderTheControls() {
        let one = NSHostingView(rootView: ControlBar("Bar") { Color.clear.frame(width: 100, height: 24) }.environment(\.offscreenSnapshot, true))
        let two = NSHostingView(
            rootView: ControlBar("Bar", summary: "Last 7 days") { Color.clear.frame(width: 100, height: 24) }.environment(\.offscreenSnapshot, true)
        )
        one.frame.size.width = 1200
        two.frame.size.width = 1200
        XCTAssertGreaterThan(two.fittingSize.height, one.fittingSize.height + DesignTokens.ControlBar.summaryGap)
    }
}
