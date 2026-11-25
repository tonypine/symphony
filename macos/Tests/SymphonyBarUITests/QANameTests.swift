import AppKit
import SwiftUI
import XCTest
@testable import SymphonyBarCore
@testable import SymphonyBarUI

/// TP-1677: `qaName` and `qaPart` record the named elements and their parts for QA mode's element report, and nothing
/// outside QA mode.
@MainActor
final class QANameTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("qa-names-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        QAElementRecorder.use(nil)
        try? FileManager.default.removeItem(at: root)
    }

    private let row = QueueRowModel(number: 3, identifier: "TP-1596", title: "A row", lead: .glyph("clock", .textSecondary), repo: "symphony")

    /// A recorder that places each view in `host`'s points: the test has no window, so no screen.
    private func makeRecorder(in host: @escaping () -> NSView?) -> QAElementRecorder {
        let window = QAElementReport.Window(number: 1, title: "Test", frame: .init(x: 0, y: 0, w: 900, h: 600), key: true)
        return QAElementRecorder(
            writer: QAElementReportWriter(file: QAMode(root: root).elementsReport(pid: 9)), pid: 9,
            now: { Date(timeIntervalSince1970: 1_800_000_000) },
            locate: { view in
                guard let host = host() else { return nil }
                let rect = view.convert(view.bounds, to: host)
                return .init(frame: .init(x: rect.minX, y: rect.minY, w: rect.width, h: rect.height), visible: true, window: window)
            }
        )
    }

    private func hosted<V: View>(_ view: V, width: CGFloat = 900, height: CGFloat = DesignTokens.HomeQueue.rowHeight) -> NSHostingView<some View> {
        let host = NSHostingView(rootView: view.frame(width: width).environment(\.offscreenSnapshot, true))
        host.frame = CGRect(x: 0, y: 0, width: width, height: height)
        host.layoutSubtreeIfNeeded()
        return host
    }

    private func probes(in view: NSView) -> [NSView] {
        view.subviews.flatMap { ($0 is QAProbeView ? [$0] : []) + probes(in: $0) }
    }

    /// c1: a queue row, which had its identifier before, is reported by that name with its parts' frames.
    func testInQAModeAQueueRowIsReportedByItsNameWithItsParts() throws {
        weak var hostView: NSView?
        let recorder = makeRecorder { hostView }
        QAElementRecorder.use(recorder)
        let host = hosted(QueueRow(row, numberWidth: QueueRow.numberWidth(widest: row.number)))
        hostView = host
        recorder.setPage(.overview, ticket: nil)

        let report = recorder.report()
        let element = try XCTUnwrap(report.elements.first { $0.name == "queue-row-TP-1596" })
        XCTAssertEqual(element.frame.w, 900)
        XCTAssertEqual(element.frame.h, DesignTokens.HomeQueue.rowHeight)
        XCTAssertTrue(element.visible)
        XCTAssertEqual(element.window, 1)
        let title = try XCTUnwrap(element.parts["title"])
        let identifier = try XCTUnwrap(element.parts["identifier"])
        XCTAssertLessThan(identifier.x, title.x)
        XCTAssertGreaterThan(title.w, 0)
        XCTAssertEqual(report.state.page, "overview")
        XCTAssertEqual(report.state.pageTitle, "Home")
        XCTAssertEqual(report.windows.map(\.number), [1])
        XCTAssertEqual(report.names, QAElementNames.scheme)
    }

    /// The parts and the selection a done row and a sidebar row report, and what is selected or focused in the state.
    func testReportsDoneRowPartsAndTheSelectedAndFocusedNames() throws {
        weak var hostView: NSView?
        let recorder = makeRecorder { hostView }
        QAElementRecorder.use(recorder)
        let host = hosted(
            VStack(spacing: 0) {
                DoneRow(DoneRowModel(identifier: "TP-7", title: "Done", repo: "symphony", when: "1h"))
                Color.clear.frame(height: 20).qaName("sidebar-home", selected: true)
                Color.clear.frame(height: 20).qaName("recently-done-head", focused: true)
                // A part outside any named element is not recorded.
                Color.clear.frame(height: 10).qaPart("stray")
            },
            height: 200
        )
        hostView = host

        let report = recorder.report()
        let done = try XCTUnwrap(report.elements.first { $0.name == "done-row-TP-7" })
        XCTAssertEqual(Set(done.parts.keys), ["identifier", "title"])
        XCTAssertEqual(report.state.selected, ["sidebar-home"])
        XCTAssertEqual(report.state.focused, ["recently-done-head"])
        XCTAssertFalse(report.elements.contains { $0.parts["stray"] != nil || $0.name == "stray" })

        // A view taken off screen leaves the report.
        for probe in probes(in: host) { recorder.unregister(probe) }
        XCTAssertEqual(recorder.report().elements, [])
    }

    /// The writer puts the report where the driver reads it.
    func testTheReportIsWrittenUnderTheQARoot() throws {
        let recorder = makeRecorder { nil }
        try QAElementReportWriter(file: QAMode(root: root).elementsReport(pid: 9)).write(recorder.report())
        let written = try QAElementReport.decoded(Data(contentsOf: root.appendingPathComponent("elements/9.json")))
        XCTAssertEqual(written.pid, 9)
        XCTAssertEqual(written.elements, [])
    }

    /// c2: outside QA mode nothing is recorded: no probe view under the named elements, no recorder, no file.
    func testOutsideQAModeNothingIsRecordedAndNoReportIsWritten() {
        QAElementRecorder.use(nil)
        QAElementRecorder.start(qaMode: nil)
        XCTAssertNil(QAElementRecorder.current)

        let host = hosted(QueueRow(row, numberWidth: QueueRow.numberWidth(widest: row.number)))
        XCTAssertEqual(probes(in: host).count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(QAMode.elementsFolder).path))
    }

    /// The names keep the identifiers window tests already find the rows by.
    func testTheRowsKeepTheirIdentifiers() {
        XCTAssertEqual(QueueRow.accessibilityIdentifier("TP-1"), "queue-row-TP-1")
        XCTAssertEqual(DoneRow.accessibilityIdentifier("TP-1"), "done-row-TP-1")
        XCTAssertEqual(QueueDropLine.accessibilityIdentifier, "queue-drop-line")
        XCTAssertEqual(SlotDropTarget.cardIdentifier(1), "slot-card-1")
        XCTAssertEqual(EpicSlotCard.identifier(1), "epic-slot-card-1")
    }
}
