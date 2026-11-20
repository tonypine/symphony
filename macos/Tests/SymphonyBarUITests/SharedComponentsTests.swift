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

    /// TP-1507 QA: Shipped's PR button sits in a row's trail; on a selected row's accent fill its words turn white,
    /// and only a quiet button's do, since every other kind draws its own face.
    func testAQuietButtonsWordsTurnWhiteOnASelectedRow() {
        XCTAssertEqual(ButtonFace<Text>.foreground(.quiet, state: .rest, onAccent: true), DesignTokens.TextColor.onAccent.color)
        XCTAssertEqual(ButtonFace<Text>.foreground(.quiet, state: .rest, onAccent: false), DesignTokens.ColorToken.accentText.color)
        XCTAssertEqual(ButtonFace<Text>.foreground(.secondary, state: .rest, onAccent: true), DesignTokens.TextColor.primary.color)
        XCTAssertEqual(ButtonFace<Text>.foreground(.quiet, state: .off, onAccent: true), DesignTokens.TextColor.tertiary.color)
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

    /// TP-1517: the label's capitals sit halfway between a button's top and bottom edges in every kind and size,
    /// within a quarter point (a centred line left them up to half a point low), its glyph is level with them, and the
    /// content keeps the size's padding on both sides.
    func testAButtonsLabelIsCentredInItsShapeInEveryKindAndSize() throws {
        for size in DesignTokens.Control.allCases {
            for kind in ButtonKind.allCases {
                for state in [DesignTokens.Interaction.rest, .hover] {
                    let plain = try XCTUnwrap(Self.ink(ButtonFace(label: Text("HHH"), kind: kind, size: size, state: state, reduceMotion: true)))
                    XCTAssertEqual(plain.runs.count, 1, "\(kind) \(size) \(state): the label alone")
                    let label = try XCTUnwrap(plain.runs.first)
                    XCTAssertEqual(plain.size.height, size.height, accuracy: 0.5)
                    XCTAssertEqual(label.middle, size.height / 2, accuracy: 0.25, "\(kind) \(size) \(state): the capitals' middle")
                    XCTAssertEqual(label.left, plain.size.width - label.right, accuracy: 0.5, "\(kind) \(size) \(state): centred across")
                    XCTAssertEqual(label.left, size.padding, accuracy: 1.5, "\(kind) \(size) \(state): the size's padding")

                    let glyphed = try XCTUnwrap(Self.ink(ButtonFace(label: Text("HHH"), kind: kind, size: size, glyph: "plus", state: state, reduceMotion: true)))
                    XCTAssertEqual(glyphed.runs.count, 2, "\(kind) \(size) \(state): the glyph and the label")
                    let glyph = try XCTUnwrap(glyphed.runs.first), words = try XCTUnwrap(glyphed.runs.last)
                    XCTAssertEqual(words.middle, size.height / 2, accuracy: 0.25, "\(kind) \(size) \(state): the capitals' middle")
                    XCTAssertEqual(glyph.middle, words.middle, accuracy: 0.5, "\(kind) \(size) \(state): the glyph on the capitals")
                    XCTAssertEqual(glyph.left, size.padding, accuracy: 2.5)
                    XCTAssertEqual(glyphed.size.width - words.right, size.padding, accuracy: 1.5)
                }
            }
        }
    }

    /// TP-1517: a menu button's title is centred down as a button's is, its chevron level with the capitals, with the
    /// catalog's padding before the title and its shorter padding after the chevron.
    func testAMenuButtonsTitleAndChevronAreCentredInItsShape() throws {
        for size in DesignTokens.Control.allCases {
            for state in [DesignTokens.Interaction.rest, .hover] {
                let face = try XCTUnwrap(Self.ink(MenuControlFace(.menu(title: "HHH", glyph: nil), size: size, state: state, reduceMotion: true)))
                XCTAssertEqual(face.runs.count, 2, "\(size) \(state): the title and the chevron")
                let title = try XCTUnwrap(face.runs.first), chevron = try XCTUnwrap(face.runs.last)
                XCTAssertEqual(title.middle, size.height / 2, accuracy: 0.25, "\(size) \(state): the capitals' middle")
                XCTAssertEqual(chevron.middle, title.middle, accuracy: 0.5, "\(size) \(state): the chevron on the capitals")
                XCTAssertEqual(title.left, size.padding, accuracy: 1.5)
                XCTAssertEqual(face.size.width - chevron.right, size.padding * DesignTokens.MenuControl.trailingScale, accuracy: 2)
            }
        }
    }

    /// TP-1517: an icon button's glyph is centred both ways in its square.
    func testAnIconButtonsGlyphIsCentredBothWays() throws {
        for size in DesignTokens.Control.allCases {
            for state in [DesignTokens.Interaction.rest, .hover] {
                let face = try XCTUnwrap(Self.ink(IconButtonFace("plus", size: size, state: state, reduceMotion: true)))
                let glyph = try XCTUnwrap(face.runs.first)
                XCTAssertEqual(face.runs.count, 1)
                XCTAssertEqual(glyph.middle, size.height / 2, accuracy: 0.25, "\(size) \(state)")
                XCTAssertEqual((glyph.left + glyph.right) / 2, size.height / 2, accuracy: 0.25, "\(size) \(state)")
            }
        }
    }

    /// TP-1517: the pointing hand over an enabled shared control, and the pointer left as it is over a disabled one.
    func testThePointerIsTheHandOnlyOverAnEnabledButton() {
        XCTAssertTrue(ButtonPointer.hand(enabled: true))
        XCTAssertFalse(ButtonPointer.hand(enabled: false))
        XCTAssertNotNil(ButtonPointer.style(enabled: true))
        XCTAssertNil(ButtonPointer.style(enabled: false))
    }

    /// One run of ink across a drawn face: its edges in points, and the middle of its top and bottom.
    struct Ink {
        var left: Double
        var right: Double
        var top: Double
        var bottom: Double
        var middle: Double { (top + bottom) / 2 }
    }

    /// Draws `face` in light at four pixels a point, and finds what is drawn on its fill (the colour 3 pt in from its
    /// left edge, halfway down): the runs of it across, apart from each other by 3 pt or more (a glyph, a label, a
    /// chevron), each with its top and bottom. The 3 pt along the top and bottom and 5 pt at each side are left out,
    /// for the face's edge, its highlight and its corners.
    static func ink(_ face: some View, scale: Double = 4) -> (size: CGSize, runs: [Ink])? {
        let renderer = ImageRenderer(content: face.environment(\.colorScheme, .light))
        renderer.scale = scale
        guard let image = renderer.cgImage, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.setFillColor(.white)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        func pixel(_ x: Int, _ y: Int) -> [Int] {
            let at = (y * width + x) * 4
            return [Int(pixels[at]), Int(pixels[at + 1]), Int(pixels[at + 2])]
        }
        let fill = pixel(Int(3 * scale), height / 2)
        let across = Int(5 * scale), down = Int(3 * scale)
        var runs: [Ink] = []
        var last: Int?
        for x in across..<(width - across) {
            let inked = (down..<(height - down)).filter { y in zip(pixel(x, y), fill).map { abs($0 - $1) }.reduce(0, +) > 3 * 96 }
            guard let top = inked.first, let bottom = inked.last else { continue }
            let column = Ink(left: Double(x) / scale, right: Double(x + 1) / scale, top: Double(top) / scale, bottom: Double(bottom + 1) / scale)
            if let last, x - last < Int(3 * scale), var run = runs.popLast() {
                run.right = column.right
                run.top = min(run.top, column.top)
                run.bottom = max(run.bottom, column.bottom)
                runs.append(run)
            } else {
                runs.append(column)
            }
            last = x
        }
        return (CGSize(width: Double(width) / scale, height: Double(height) / scale), runs)
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
