import AppKit
import SwiftUI
import XCTest
@testable import SymphonyBarUI

/// TP-1490: an Insights page whose numbers Symphony couldn't serve drew its control bar in the middle of the page, with
/// an empty band above it, because the short "Update Symphony" state left the bar and the state centred together. The
/// page now pins the bar at the top and gives the state the rest.
@MainActor
final class PinnedBarPageTests: XCTestCase {
    /// An AppKit view placed in the bar, so the test reads where the page put the bar.
    private struct Marker: NSViewRepresentable {
        let view: NSView

        func makeNSView(context _: Context) -> NSView { view }
        func updateNSView(_: NSView, context _: Context) {}
    }

    /// The bar's frame in the page's coordinates, its top measured down from the page's top.
    private func barFrame(page size: CGSize, @ViewBuilder content: () -> some View) -> (top: CGFloat, height: CGFloat) {
        let marker = NSView()
        let host = NSHostingView(rootView: PinnedBarPage {
            Marker(view: marker).frame(height: 40)
        } content: {
            content()
        })
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        let frame = marker.convert(marker.bounds, to: host)
        let top = host.isFlipped ? frame.minY : host.bounds.height - frame.maxY
        return (top, frame.height)
    }

    func testTheBarStaysAtTheTopOverAShortState() {
        let bar = barFrame(page: CGSize(width: 1200, height: 800)) {
            EmptyState(title: "Update Symphony to see this view.", symbol: "arrow.down.circle")
        }
        XCTAssertEqual(bar.top, 0, accuracy: 0.5)
        XCTAssertEqual(bar.height, 40, accuracy: 0.5)
    }

    func testTheBarStaysAtTheTopOverASpinner() {
        let bar = barFrame(page: CGSize(width: 1200, height: 800)) {
            EmptyState(title: "Reading Symphony's numbers…", symbol: "chart.bar", showsSpinner: true)
        }
        XCTAssertEqual(bar.top, 0, accuracy: 0.5)
    }

    func testTheBarStaysAtTheTopOverContentThatFills() {
        let bar = barFrame(page: CGSize(width: 1200, height: 800)) {
            ScrollView { Color.clear.frame(height: 2000) }
        }
        XCTAssertEqual(bar.top, 0, accuracy: 0.5)
        XCTAssertEqual(bar.height, 40, accuracy: 0.5)
    }
}
