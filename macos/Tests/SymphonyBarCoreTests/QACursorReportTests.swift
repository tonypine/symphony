import XCTest
@testable import SymphonyBarCore

/// TP-1678: QA mode's cursor report, the file `qa_hover` reads: where it goes, its shape, and which cursor it names.
final class QACursorReportTests: XCTestCase {
    private let field = QACursorReport.Recorded(cursor: .iBeam, element: "name-field", frame: .init(x: 10, y: 20, w: 200, h: 28))

    func testTheReportGoesUnderTheQARootOneFilePerProcess() {
        let mode = QAMode(root: URL(fileURLWithPath: "/tmp/qa-root", isDirectory: true))
        XCTAssertEqual(mode.cursorReport(pid: 42).path, "/tmp/qa-root/cursor/42.json")
        XCTAssertEqual(QAMode.cursorFolder, "cursor")
    }

    func testARecordedPlaceNamesTheCursorAndItsElement() {
        let report = QACursorReport(at: Date(), pid: 1, pointer: .init(x: 5, y: 6), recorded: field, appCursor: "i_beam")
        XCTAssertEqual(report.cursor, .iBeam)
        XCTAssertEqual(report.element, "name-field")
        XCTAssertEqual(report.source, .recorded)
    }

    func testNothingRecordedIsTheArrowThatNoElementSet() {
        for held in [nil, "arrow", "unnamed"] {
            let report = QACursorReport(at: Date(), pid: 1, pointer: .init(x: 5, y: 6), recorded: nil, appCursor: held)
            XCTAssertEqual(report.cursor, .arrow)
            XCTAssertNil(report.element)
            XCTAssertEqual(report.source, QACursorReport.Source.none)
        }
    }

    func testANamedCursorNoRecordedPlaceSetIsUnrecorded() {
        let bare = QACursorReport.resolve(recorded: nil, appCursor: "resize_up_down")
        XCTAssertEqual(bare.cursor, .resizeUpDown)
        XCTAssertNil(bare.element)
        XCTAssertEqual(bare.source, .unrecorded)

        let other = QACursorReport.resolve(recorded: field, appCursor: "pointing_hand")
        XCTAssertEqual(other.cursor, .pointingHand)
        XCTAssertEqual(other.source, .unrecorded)

        let arrow = QACursorReport.resolve(recorded: field, appCursor: "arrow")
        XCTAssertEqual(arrow.source, .recorded, "the arrow the app still holds is never a finding")
    }

    func testTheFileHasSnakeCaseKeysAndReadsBack() throws {
        let report = QACursorReport(
            at: Date(timeIntervalSince1970: 1_800_000_000), pid: 7, pointer: .init(x: 1.234, y: 5), recorded: field,
            appCursor: "vertical_i_beam"
        )
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: report.encoded()) as? [String: Any])
        XCTAssertEqual(json["version"] as? Int, 1)
        XCTAssertEqual(json["cursor"] as? String, "vertical_i_beam")
        XCTAssertEqual(json["source"] as? String, "unrecorded")
        XCTAssertEqual(json["app_cursor"] as? String, "vertical_i_beam")
        XCTAssertNil(json["element"])
        XCTAssertEqual((json["recorded"] as? [String: Any])?["element"] as? String, "name-field")
        XCTAssertEqual((json["pointer"] as? [String: Any])?["x"] as? Double, 1.23)
        XCTAssertEqual(try QACursorReport.decoded(report.encoded()), report)
    }

    func testTheWriterWritesOnlyWhatChanged() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("qa-cursor-core-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = QACursorReportWriter(file: QAMode(root: root).cursorReport(pid: 3))
        let first = QACursorReport(at: Date(timeIntervalSince1970: 1), pid: 3, pointer: .init(x: 0, y: 0), recorded: nil, appCursor: nil)
        let later = QACursorReport(at: Date(timeIntervalSince1970: 2), pid: 3, pointer: .init(x: 0, y: 0), recorded: nil, appCursor: nil)
        XCTAssertTrue(first.sameAs(later))
        XCTAssertTrue(try writer.write(first))
        XCTAssertFalse(try writer.write(later))
        let moved = QACursorReport(at: Date(timeIntervalSince1970: 3), pid: 3, pointer: .init(x: 1, y: 0), recorded: nil, appCursor: nil)
        XCTAssertTrue(try writer.write(moved))
        XCTAssertEqual(try QACursorReport.decoded(Data(contentsOf: writer.file)).pointer, .init(x: 1, y: 0))
    }
}
