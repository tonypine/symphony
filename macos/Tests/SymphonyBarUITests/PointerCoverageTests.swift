import SwiftUI
import XCTest
@testable import SymphonyBarUI

/// TP-1572: everything a person can click in the app shows the pointing hand while it can act. The pointer is set once
/// in each button style and clickable component (`buttonPointer`), and this sweep of the app's sources keeps a new one
/// from being added without it: no bare `.plain` button, no button style without the pointer, no click gesture without
/// it unless it is listed below with why it keeps the arrow.
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

    func testNoButtonIsLeftAPlainButtonWithoutThePointer() throws {
        for (name, lines) in try files() {
            for (index, line) in lines.enumerated() where line.contains(".buttonStyle(.plain)") || line.contains(".buttonStyle(.borderless)") {
                // The plain pointer style itself wraps `.plain`.
                if name == "InteractionStyles.swift", lines[index + 1].contains(".buttonPointer()") { continue }
                XCTFail("\(name):\(index + 1) uses a bare plain button; use `.buttonStyle(.plainPointer)`")
            }
        }
    }

    func testEveryButtonStyleSetsThePointer() throws {
        var styles = 0
        for (name, lines) in try files() {
            for (index, line) in lines.enumerated() where line.contains(": ButtonStyle {") {
                styles += 1
                let body = lines[index...].prefix { !$0.hasPrefix("}") }
                XCTAssertTrue(body.contains { $0.contains(".buttonPointer(") }, "\(name):\(index + 1) \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        XCTAssertGreaterThanOrEqual(styles, 10, "the sweep finds the app's button styles")
    }

    func testEveryClickGestureSetsThePointerOrSaysWhyNot() throws {
        var gestures = 0
        for (name, lines) in try files() {
            for (index, line) in lines.enumerated() where line.contains(".onTapGesture") {
                gestures += 1
                let gesture = line.trimmingCharacters(in: .whitespaces)
                if Self.arrowTaps.contains(where: { $0.file == name && $0.line == gesture }) { continue }
                let after = lines[(index + 1)...].prefix(Self.reach)
                XCTAssertTrue(after.contains { $0.contains(".buttonPointer(") }, "\(name):\(index + 1) \(gesture) has no pointer")
            }
        }
        XCTAssertGreaterThanOrEqual(gestures, 15, "the sweep finds the app's click gestures")
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
