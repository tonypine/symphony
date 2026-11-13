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

    // MARK: - Button and icon button (TP-1505)

    func testTheButtonKindsAreTheCatalogsVariants() {
        XCTAssertEqual(ButtonKind.allCases.map(\.rawValue), ["primary", "secondary", "quiet", "destructive", "destructive-filled"])
    }

    func testAButtonIsItsSizesHeightInEveryKindAndState() {
        let states: [DesignTokens.Interaction] = [.rest, .hover, .press, .focus, .off]
        for size in DesignTokens.Control.allCases {
            XCTAssertEqual([size.glyphSize, size.iconGlyphSize], [[12, 14], [14, 16], [16, 18]][size == .small ? 0 : size == .medium ? 1 : 2])
            for kind in ButtonKind.allCases {
                for state in states {
                    let face = ButtonFace(label: Text("Approve Plan"), kind: kind, size: size, glyph: "arrow.clockwise", state: state, reduceMotion: false)
                    XCTAssertEqual(fittingSize(face).height, size.height, accuracy: 0.5, "\(kind) \(size) \(state)")
                }
            }
        }
    }

    func testAnIconButtonIsSquareAtEachSize() {
        for size in DesignTokens.Control.allCases {
            for on in [false, true] {
                let face = fittingSize(IconButtonFace("sidebar.right", size: size, on: on, state: .rest, reduceMotion: true))
                XCTAssertEqual(face.width, size.height, accuracy: 0.5, "\(size)")
                XCTAssertEqual(face.height, size.height, accuracy: 0.5, "\(size)")
            }
        }
    }

    /// A disabled control draws its reason under it, without a press: it is taller than the control alone.
    func testADisabledButtonDrawsItsReasonUnderIt() {
        let on = fittingSize(Button("Stop Run…") {}.directorButton(.destructive))
        let off = fittingSize(Button("Stop Run…") {}.directorButton(.destructive, disabledReason: "No run is working."))
        XCTAssertEqual(on.height, DesignTokens.Control.medium.height, accuracy: 0.5)
        XCTAssertGreaterThan(off.height, on.height + DesignTokens.Control.glyphGap)
        let icon = fittingSize(IconButton("sidebar.right", help: "Show the details pane") {})
        let iconOff = fittingSize(IconButton("sidebar.right", help: "Show the details pane", disabledReason: "No ticket is selected.") {})
        XCTAssertEqual(icon.height, DesignTokens.Control.medium.height, accuracy: 0.5)
        XCTAssertGreaterThan(iconOff.height, icon.height + DesignTokens.Control.glyphGap)
    }
    /// A reason keeps its size in a narrow place: squeezed, it would wrap a word a line, and that height would become
    /// the window's minimum and push its bottom bar off screen (the Repos window at its opening size).
    func testAReasonKeepsItsHeightWhenItsContainerIsNarrow() {
        let free = fittingSize(Refusal(reason: "Select a repo first."))
        let squeezed = fittingSize(Refusal(reason: "Select a repo first.").frame(width: 12))
        XCTAssertEqual(squeezed.height, free.height, accuracy: 0.5)
        let bar = fittingSize(
            HStack(alignment: .top) {
                IconButton("minus", help: "Disconnect", size: .small, disabledReason: "Select a repo first.", reasonAlignment: .leading) {}
            }
            .frame(width: 40)
        )
        XCTAssertLessThan(bar.height, DesignTokens.Control.small.height + DesignTokens.Control.glyphGap + 2 * free.height)
    }
}
