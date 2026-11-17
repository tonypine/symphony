import AppKit
import SwiftUI
import XCTest
@testable import SymphonyBarCore
@testable import SymphonyBarUI

/// TP-1511: the catalog's Key-value list and Collapsible card as the app lays them out. A list's values start in one
/// column, past its longest label, or under their labels when stacked, and an unknown fact takes no room; a card is
/// its 48 pt head while folded or empty, and opens its body under the head, inset past the chevron.
@MainActor
final class KeyValueAndCollapsibleTests: XCTestCase {
    /// An AppKit view placed in a layout, so the test reads where the layout put it.
    private struct Marker: NSViewRepresentable {
        let view: NSView

        func makeNSView(context _: Context) -> NSView { view }
        func updateNSView(_: NSView, context _: Context) {}
    }

    private func laidOut(_ view: some View, width: CGFloat = 360) -> NSView {
        let host = NSHostingView(rootView: view.frame(width: width))
        host.frame = CGRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        return host
    }

    /// Where `marker` sits in `host`, from its top-left corner.
    private func place(_ marker: NSView, in host: NSView) -> CGRect {
        let frame = marker.convert(marker.bounds, to: host)
        let top = host.isFlipped ? frame.minY : host.bounds.height - frame.maxY
        return CGRect(x: frame.minX, y: top, width: frame.width, height: frame.height)
    }

    private func width(of label: String, _ style: DesignTokens.TypeStyle) -> CGFloat {
        NSHostingView(rootView: Text(label).textStyle(style).fixedSize()).fittingSize.width
    }

    // MARK: - Key-value list

    func testTheValuesStartInOneColumnPastTheLongestLabel() {
        let short = NSView()
        let long = NSView()
        let host = laidOut(
            KeyValueList {
                KeyValueRow("Repo") { Marker(view: short).frame(width: 40, height: 16) }
                KeyValueRow("Waiting since") { Marker(view: long).frame(width: 40, height: 16) }
            }
        )
        let first = place(short, in: host)
        let second = place(long, in: host)
        XCTAssertEqual(first.minX, second.minX, accuracy: 0.5)
        XCTAssertEqual(first.minX, width(of: "Waiting since", .body) + CGFloat(DesignTokens.KeyValue.columnGap), accuracy: 1)
        XCTAssertGreaterThan(second.minY, first.maxY)
    }

    func testStackedEachValueSitsUnderItsLabel() {
        let value = NSView()
        let host = laidOut(
            KeyValueList(layout: .stacked) {
                KeyValueRow("Waiting since") { Marker(view: value).frame(width: 40, height: 16) }
            }
        )
        let spot = place(value, in: host)
        XCTAssertEqual(spot.minX, 0, accuracy: 0.5)
        XCTAssertGreaterThan(spot.minY, CGFloat(DesignTokens.KeyValue.stackedLabelGap))
    }

    func testAnUnknownFactIsLeftOut() {
        let known = laidOut(KeyValueList { KeyValueRow("Runs", text: "3 · 1 h 12 min") })
        let withUnknown = laidOut(
            KeyValueList {
                KeyValueRow("Runs", text: "3 · 1 h 12 min")
                KeyValueRow("Tokens", text: nil)
                KeyValueRow("Part of", text: "")
            }
        )
        XCTAssertEqual(withUnknown.bounds.height, known.bounds.height, accuracy: 0.5)
    }

    func testAHeadedGroupPutsItsHeadingAboveItsFacts() {
        let value = NSView()
        let headed = laidOut(KeyValueList(heading: "Work") { KeyValueRow("Runs") { Marker(view: value).frame(width: 40, height: 16) } })
        XCTAssertGreaterThan(place(value, in: headed).minY, CGFloat(DesignTokens.KeyValue.groupHeadingGap))
        let groups = laidOut(
            KeyValueGroups {
                KeyValueList(heading: "Ticket") { KeyValueRow("Repo", text: "symphony") }
                KeyValueList(heading: "Work") { KeyValueRow("Runs", text: "3") }
            }
        )
        XCTAssertGreaterThan(groups.bounds.height, 2 * headed.bounds.height - 1)
    }

    func testAPathValueCopiesItsPath() {
        var copied: [String] = []
        let path = KeyValuePath("/tmp/workspaces/TP-1511", copyLabel: "Copy the workspace path") { copied.append($0) }
        XCTAssertGreaterThan(laidOut(path).bounds.height, 0)
        path.copy("/tmp/workspaces/TP-1511")
        XCTAssertEqual(copied, ["/tmp/workspaces/TP-1511"])
        XCTAssertEqual(KeyValuePath.copyTitle, "Copy")
        XCTAssertEqual(KeyValuePath.copiedTitle, "Copied")
        XCTAssertGreaterThan(laidOut(KeyValuePath("/tmp", copied: true) { _ in }).bounds.height, 0)
    }

    // MARK: - Collapsible card

    private func card(expanded: Bool, empty: Bool = false, drawnAs: DesignTokens.Interaction? = nil, body marker: NSView) -> some View {
        CollapsibleCard("Earlier runs", summary: "3 runs · 1 h 12 min", expanded: .constant(expanded), empty: empty, drawnAs: drawnAs) {
            Marker(view: marker).frame(width: 100, height: 40)
        }
    }

    func testAFoldedCardIsItsHead() {
        let host = laidOut(card(expanded: false, body: NSView()), width: 520)
        XCTAssertEqual(host.bounds.height, CGFloat(DesignTokens.Collapsible.headMinHeight), accuracy: 0.5)
    }

    func testAnOpenCardDrawsItsBodyUnderTheHeadPastTheChevron() {
        let marker = NSView()
        let host = laidOut(card(expanded: true, body: marker), width: 520)
        let spot = place(marker, in: host)
        XCTAssertEqual(spot.minX, CGFloat(DesignTokens.Collapsible.bodyLeadingPadding), accuracy: 0.5)
        XCTAssertEqual(spot.minY, CGFloat(DesignTokens.Collapsible.headMinHeight), accuracy: 0.5)
        XCTAssertEqual(host.bounds.height, CGFloat(DesignTokens.Collapsible.headMinHeight + DesignTokens.Collapsible.bodyPadding) + 40, accuracy: 0.5)
    }

    func testAnEmptyCardCannotOpen() {
        let host = laidOut(card(expanded: true, empty: true, body: NSView()), width: 520)
        XCTAssertEqual(host.bounds.height, CGFloat(DesignTokens.Collapsible.headMinHeight), accuracy: 0.5)
    }

    func testTheHeadsStatesDrawAtTheirSize() {
        for state in [DesignTokens.Interaction.hover, .focus, .press] {
            XCTAssertEqual(laidOut(card(expanded: false, drawnAs: state, body: NSView()), width: 520).bounds.height, 48, accuracy: 0.5)
        }
        let line = CollapsibleHead(expanded: true, style: .line, summary: "2 runs", accessibilityLabel: "Models", toggle: {}) { Text("Models") }
        XCTAssertGreaterThan(laidOut(line).bounds.height, 0)
    }

    func testAFoldBodyIsThereOnlyWhileOpen() {
        let shut = laidOut(VStack(spacing: 0) { FoldBody(expanded: false) { Color.clear.frame(height: 40) } })
        let open = laidOut(VStack(spacing: 0) { FoldBody(expanded: true) { Color.clear.frame(height: 40).foldRow(0) } })
        XCTAssertEqual(shut.bounds.height, 0, accuracy: 0.5)
        XCTAssertEqual(open.bounds.height, 40, accuracy: 0.5)
        XCTAssertNotNil(FoldMotion.opening(reduceMotion: true))
    }
}
