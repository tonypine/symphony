import AppKit
import SwiftUI
import XCTest
@testable import SymphonyBarCore
@testable import SymphonyBarUI

/// TP-1484: the catalog's panel, zone title and chip as the app draws them. A chip is the catalog's height in each of
/// its kinds, a panel insets its content by the catalog's padding, and a zone title reads its note after its name.
@MainActor
final class SharedComponentsTests: XCTestCase {
    /// An AppKit view placed in a layout, so the test reads where the layout put it.
    private struct Marker: NSViewRepresentable {
        let view: NSView

        func makeNSView(context _: Context) -> NSView { view }
        func updateNSView(_: NSView, context _: Context) {}
    }

    private func fittingSize(_ view: some View) -> CGSize {
        let host = NSHostingView(rootView: view)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }

    func testEveryChipIsTheSmallControlsHeightAndALabelChipIsTwentyPoints() {
        XCTAssertEqual(Chip.height, 24)
        let kinds: [Chip.Kind] = [.plain, .repo, .epic] + DesignTokens.Status.allCases.map { .status($0) }
        for kind in kinds {
            XCTAssertEqual(fittingSize(Chip("symphony", kind: kind)).height, 24, accuracy: 0.5, "\(kind)")
        }
        XCTAssertEqual(fittingSize(Chip("qa:skip", kind: .label(.idle))).height, 20, accuracy: 0.5)
    }

    func testAChipCarriesItsKindsGlyph() {
        XCTAssertNil(Chip.Kind.plain.symbol)
        XCTAssertNil(Chip.Kind.label(.working).symbol)
        XCTAssertEqual(Chip.Kind.repo.symbol, SymphonyView.repos.symbol)
        XCTAssertEqual(Chip.Kind.epic.symbol, SymphonyView.initiatives.symbol)
        XCTAssertEqual(Chip.Kind.status(.you).symbol, DesignTokens.Status.you.symbol)
        // The glyph and its gap widen the chip beside a plain one with the same text.
        XCTAssertGreaterThan(fittingSize(Chip("symphony", kind: .repo)).width, fittingSize(Chip("symphony")).width)
    }

    func testAPanelInsetsItsContentByTheCatalogsPadding() {
        XCTAssertEqual(PanelStyle.padding, EdgeInsets(top: 16, leading: 20, bottom: 16, trailing: 20))
        let marker = NSView()
        let host = NSHostingView(rootView: Panel { Marker(view: marker).frame(width: 100, height: 40) }.frame(width: 300))
        host.frame = CGRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        let frame = marker.convert(marker.bounds, to: host)
        let top = host.isFlipped ? frame.minY : host.bounds.height - frame.maxY
        XCTAssertEqual(frame.minX, 20, accuracy: 0.5)
        XCTAssertEqual(top, 16, accuracy: 0.5)
        XCTAssertEqual(host.bounds.height, 40 + 32, accuracy: 0.5)
    }

    func testAZoneTitleReadsItsNoteAfterItsName() {
        XCTAssertEqual(ZoneTitle("Lifecycle").accessibilityText, "Lifecycle")
        XCTAssertEqual(ZoneTitle("Timeline", note: "3 new").accessibilityText, "Timeline, 3 new")
        XCTAssertEqual(
            ZoneTitle("Timeline", note: "3 new", noteAccessibilityLabel: "3 new since you last looked").accessibilityText,
            "Timeline, 3 new since you last looked"
        )
    }

    func testTheZoneTitleIsInTheCaptionStyleAndSitsTwoSpacesAboveItsPanel() {
        XCTAssertEqual(ZoneTitle.gap, DesignTokens.Space.s2)
        XCTAssertEqual(ZoneTitle.tracking, 0.08)
        // One line of the caption style: 13 pt high.
        let height = fittingSize(ZoneTitle("Pull request").frame(width: 300)).height
        XCTAssertEqual(height, DesignTokens.TypeStyle.caption.scaledLineHeight(by: DesignTokens.TypeStyle.textScale), accuracy: 1)
    }
}
