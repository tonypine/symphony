import SwiftUI
import XCTest
@testable import SymphonyBarUI

/// TP-1572: everything a person can click in the app shows the pointing hand while it can act. The pointer is set once
/// in each button style and clickable component (`buttonPointer`), and once on every window's, sheet's and popover's
/// root for the buttons that set no style (`pointerButtons`). This sweep of the app's sources keeps a new one from being
/// added without it: no bare system style on a button, no button style without the pointer, no root without
/// `pointerButtons`, and no click gesture without the pointer unless it is listed below with why it keeps the arrow.
final class PointerCoverageTests: XCTestCase {
    private static let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources")

    /// The click gestures that keep the arrow, by file and the gesture's line, with why.
    private static let arrowTaps: [(file: String, line: String, why: String)] = [
        ("QuestionBlock.swift", ".onTapGesture { isPresented = false }", "the dimmed page behind the decision sheet"),
        ("ImageViewer.swift", ".onTapGesture(count: 2) { model.toggleFittedAndActualSize() }", "a double click on the picture zooms it"),
        ("TextInputs.swift", ".onTapGesture { if !disabled, !still { focusBinding.wrappedValue = true } }", "a text field keeps the I-beam"),
        ("TextInputs.swift", ".onTapGesture { if !still { takeKeyboard() } }", "a text field keeps the I-beam"),
        ("TextInputs.swift", ".onTapGesture { if !drawsStill { focusBinding.wrappedValue = true } }", "a text field keeps the I-beam"),
        ("ListComponents.swift", "content.onTapGesture { (open ?? select)?() }", "the row's pointer is set around `clicks`"),
        ("ListComponents.swift", ".onTapGesture(count: 2) { open?() }", "the row's pointer is set around `clicks`"),
        ("ListComponents.swift", ".simultaneousGesture(TapGesture().onEnded { select?() })", "the row's pointer is set around `clicks`"),
        ("TimelineSection.swift", "DragGesture(minimumDistance: 0).onEnded { value in", "a run's line only takes the keyboard; its fold header has the hand"),
    ]

    /// The SwiftUI roots that draw nothing a person sees, by file and line.
    private static let unseenRoots: [(file: String, line: String, why: String)] = [
        ("TicketsTableView.swift", "NSHostingView(rootView: Badge(status: .forced, size: .small).fixedSize())", "measures a badge's width"),
    ]

    /// How many lines after a click gesture its pointer may come, in the same chain of modifiers.
    private static let reach = 3

    private func files() throws -> [(name: String, lines: [String])] {
        let roots = ["SymphonyBar", "SymphonyBarUI"].map { Self.sources.appendingPathComponent($0) }
        var found: [(String, [String])] = []
        for root in roots {
            let walker = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
            for case let url as URL in walker where url.pathExtension == "swift" {
                let text = try String(contentsOf: url, encoding: .utf8)
                found.append((url.lastPathComponent, text.components(separatedBy: "\n")))
            }
        }
        XCTAssertGreaterThan(found.count, 50, "the sweep reads the app's sources")
        return found
    }

    /// A system style set on a button replaces the root's `.systemPointer`, so a button sets `.plainPointer`, the
    /// Director's styles or none, never `.plain`, `.borderless`, `.bordered`, `.borderedProminent`, `.link` or
    /// `.automatic` by itself.
    func testNoButtonSetsASystemStyleWithoutThePointer() throws {
        let bare = [".plain)", ".borderless)", ".bordered)", ".borderedProminent)", ".link)", ".automatic)", ".accessoryBar)"]
        for (name, lines) in try files() {
            for (index, line) in lines.enumerated() where bare.contains(where: { line.contains(".buttonStyle(\($0)") }) {
                // The pointer styles themselves wrap the system's.
                if name == "InteractionStyles.swift", lines[index + 1].contains(".buttonPointer()") { continue }
                XCTFail("\(name):\(index + 1) \(line.trimmingCharacters(in: .whitespaces)) has no pointer; use `.plainPointer` or no style")
            }
        }
    }

    /// Every window, panel and popover the app hosts, and every sheet and popover it presents, gives the buttons under
    /// it that set no style the pointing hand: a default system button (Cancel, Undo, Check Now) is never left with the
    /// arrow, wherever it is added.
    func testEveryRootGivesItsDefaultButtonsThePointer() throws {
        var roots = 0
        for (name, lines) in try files() {
            for (index, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("init(") || trimmed.hasPrefix("required init") { continue }
                if line.contains("NSHostingController(") || line.contains("NSHostingView(rootView:") || line.contains("MenuHostingView(rootView:") {
                    if Self.unseenRoots.contains(where: { $0.file == name && line.contains($0.line) }) { continue }
                    roots += 1
                    let chain = lines[index...].prefix(3)
                    XCTAssertTrue(chain.contains { $0.contains(".pointerButtons()") }, "\(name):\(index + 1) \(trimmed) hosts no pointerButtons()")
                } else if line.contains(".sheet(") || line.contains(".popover(") {
                    roots += 1
                    let indent = line.prefix { $0 == " " }.count
                    let content = lines[(index + 1)...].prefix { !($0.trimmingCharacters(in: .whitespaces) == "}" && $0.prefix { $0 == " " }.count == indent) }
                    XCTAssertTrue(content.contains { $0.contains(".pointerButtons()") }, "\(name):\(index + 1) \(trimmed) presents no pointerButtons()")
                }
            }
        }
        XCTAssertGreaterThanOrEqual(roots, 15, "the sweep finds the app's windows, sheets and popovers")
    }

    /// The root's style is the system's own button with the hand while it is enabled.
    @MainActor
    func testTheRootStyleIsTheSystemButtonWithThePointer() {
        XCTAssertNotNil(ButtonPointer.style(enabled: true))
        XCTAssertNil(ButtonPointer.style(enabled: false))
        let renderer = ImageRenderer(content: Button("Undo") {}.pointerButtons().padding())
        XCTAssertNotNil(renderer.nsImage, "a default button under pointerButtons() still draws")
    }

    func testEveryButtonStyleSetsThePointer() throws {
        var styles = 0
        for (name, lines) in try files() {
            for (index, line) in lines.enumerated() where line.contains(": ButtonStyle {") || line.contains(": PrimitiveButtonStyle {") {
                styles += 1
                let body = lines[index...].prefix { !$0.hasPrefix("}") }
                XCTAssertTrue(body.contains { $0.contains(".buttonPointer(") }, "\(name):\(index + 1) \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        XCTAssertGreaterThanOrEqual(styles, 10, "the sweep finds the app's button styles")
    }

    /// A click gesture: a tap, or a press read as a click when it ends (a drag of no distance whose end does more than
    /// let go of the press look).
    private static func isClick(_ lines: ArraySlice<String>, at index: Int) -> Bool {
        let line = lines[index]
        if line.contains(".onTapGesture") || line.contains("TapGesture()") { return true }
        guard line.contains("DragGesture(minimumDistance: 0)") else { return false }
        let block = lines[index...].prefix { !$0.trimmingCharacters(in: .whitespaces).hasPrefix(")") }
        guard let ended = block.firstIndex(where: { $0.contains(".onEnded") }) else { return false }
        let end = block[ended...].joined(separator: " ")
            .replacingOccurrences(of: #"\.onEnded|\{ *_ in|\{ *value in|pressed = \w+|[{}\s]"#, with: "", options: .regularExpression)
        return !end.isEmpty
    }

    func testEveryClickGestureSetsThePointerOrSaysWhyNot() throws {
        var gestures = 0
        for (name, lines) in try files() {
            let all = ArraySlice(lines)
            for index in all.indices where Self.isClick(all, at: index) {
                gestures += 1
                let gesture = lines[index].trimmingCharacters(in: .whitespaces)
                if Self.arrowTaps.contains(where: { $0.file == name && $0.line == gesture }) { continue }
                // In the same chain of modifiers: a few lines before the gesture, or after its block ends.
                let blockEnd = all[index...].firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix(")") } ?? index
                let end = lines[index].contains("DragGesture") ? blockEnd : index
                let near = all[max(0, index - Self.reach - 1)..<index] + all[(end + 1)...].prefix(Self.reach)
                XCTAssertTrue(near.contains { $0.contains(".buttonPointer(") }, "\(name):\(index + 1) \(gesture) has no pointer")
            }
        }
        XCTAssertGreaterThanOrEqual(gestures, 20, "the sweep finds the app's click gestures")
    }

    /// The exemptions name gestures that are still there: a stale one would hide a new gesture written the same way.
    func testEveryGestureThatKeepsTheArrowIsStillThere() throws {
        let all = try files()
        for tap in Self.arrowTaps {
            let lines = all.filter { $0.name == tap.file }.flatMap(\.lines).map { $0.trimmingCharacters(in: .whitespaces) }
            XCTAssertTrue(lines.contains(tap.line), "\(tap.file): \(tap.line) (\(tap.why)) is gone")
        }
    }
}
