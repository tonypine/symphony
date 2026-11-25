import AppKit
import SwiftUI
import XCTest
@testable import SymphonyBarCore
@testable import SymphonyBarUI

/// TP-1678: in QA mode the places that set a cursor record the kind they set and the named element it applies to, the
/// recorder reports the one under the pointer, a cursor the app holds that none of them set is reported as set outside
/// them, and outside QA mode nothing is recorded or written.
@MainActor
final class QACursorTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("qa-cursor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        QACursorRecorder.use(nil)
        try? FileManager.default.removeItem(at: root)
    }

    private var file: URL { QAMode(root: root).cursorReport(pid: 9) }

    /// A recorder that places each view in `host`'s points (the test has no window, so no screen), with the pointer at
    /// `pointer` in those points and `held` as the cursor the app holds.
    private func makeRecorder(
        in host: @escaping () -> NSView?, pointer: QACursorReport.Point, held: String? = "arrow", front: Int? = 1
    ) -> QACursorRecorder {
        QACursorRecorder(
            writer: QACursorReportWriter(file: file), pid: 9, now: { Date(timeIntervalSince1970: 1_800_000_000) },
            locate: { view in
                guard let host = host() else { return nil }
                let rect = view.convert(view.bounds, to: host)
                guard rect.width > 0, rect.height > 0 else { return nil }
                return .init(shown: .init(x: rect.minX, y: rect.minY, w: rect.width, h: rect.height), window: 1)
            },
            pointer: { pointer }, windowAt: { _ in front }, appCursor: { held }
        )
    }

    private func hosted<V: View>(_ view: V, width: CGFloat = 400, height: CGFloat = 60) -> NSHostingView<some View> {
        let host = NSHostingView(rootView: view.frame(width: width, height: height))
        host.frame = CGRect(x: 0, y: 0, width: width, height: height)
        host.layoutSubtreeIfNeeded()
        return host
    }

    private func probes(in view: NSView) -> [NSView] {
        view.subviews.flatMap { ($0 is QACursorProbeView ? [$0] : []) + probes(in: $0) }
    }

    /// Hosts `view` and returns what the recorder reports at the centre of each probe view: `<kind> <element>`.
    private func recordedKinds<V: View>(_ view: V, height: CGFloat = 60) -> Set<String> {
        weak var hostView: NSView?
        let recorder = makeRecorder(in: { hostView }, pointer: .init(x: 0, y: 0))
        QACursorRecorder.use(recorder)
        let host = hosted(view, height: height)
        hostView = host
        return Set(probes(in: host).compactMap { probe in
            let rect = probe.convert(probe.bounds, to: host)
            return recorder.recorded(at: .init(x: rect.midX, y: rect.midY)).map { "\($0.cursor.rawValue) \($0.element ?? "-")" }
        })
    }

    /// Hosts `view` with a recorder whose pointer is at the host's centre, and returns the report there.
    private func report<V: View>(_ view: V, held: String? = "arrow") -> QACursorReport {
        weak var hostView: NSView?
        let recorder = makeRecorder(in: { hostView }, pointer: .init(x: 200, y: 30), held: held)
        QACursorRecorder.use(recorder)
        let host = hosted(view)
        hostView = host
        let report = recorder.report()
        withExtendedLifetime(host) {}
        return report
    }

    // MARK: - c1: each place records its cursor and its element

    func testTheSharedButtonPointerRecordsThePointingHandForTheNamedButton() {
        let report = report(
            Button("Open") {}.buttonStyle(.plainPointer).frame(maxWidth: .infinity, maxHeight: .infinity).qaName("open-button")
        )
        XCTAssertEqual(report.cursor, .pointingHand)
        XCTAssertEqual(report.element, "open-button")
        XCTAssertEqual(report.source, .recorded)
        XCTAssertEqual(report.recorded?.cursor, .pointingHand)
    }

    func testADisabledButtonRecordsNoCursorSoTheArrowShows() {
        let report = report(
            Button("Open") {}.buttonStyle(.plainPointer).disabled(true).frame(maxWidth: .infinity, maxHeight: .infinity)
                .qaName("open-button")
        )
        XCTAssertEqual(report.cursor, .arrow)
        XCTAssertNil(report.element)
        XCTAssertEqual(report.source, QACursorReport.Source.none)
        XCTAssertNil(report.recorded)
    }

    func testATextFieldRecordsTheIBeamForItsName() {
        let report = report(DirectorTextField(nil, text: .constant(""), placeholder: "Name").qaName("name-field"))
        XCTAssertEqual(report.cursor, .iBeam)
        XCTAssertEqual(report.element, "name-field")
    }

    func testATextAreaAndANumberFieldRecordTheIBeam() {
        let area = report(TextArea("Notes", text: .constant("")).qaName("notes"))
        XCTAssertEqual(area.cursor, .iBeam)
        XCTAssertEqual(area.element, "notes")
        let number = recordedKinds(NumberField(value: .constant(3), in: 1...9).qaName("slots"))
        XCTAssertTrue(number.contains("i_beam slots"), "\(number)")
        XCTAssertTrue(number.contains("pointing_hand slots"), "the stepper's buttons: \(number)")
    }

    func testTheNotAllowedPointerRecordsItsKindOnlyWhileTheControlIsRefused() {
        let refused = report(Color.clear.notAllowedPointer(true).qaName("refused-move"))
        XCTAssertEqual(refused.cursor, .operationNotAllowed)
        XCTAssertEqual(refused.element, "refused-move")
        let allowed = report(Color.clear.notAllowedPointer(false).qaName("refused-move"))
        XCTAssertEqual(allowed.cursor, .arrow)
    }

    func testTheReorderGrabRecordsTheOpenHandOnItsHandle() {
        struct Line: Identifiable { let id: Int }
        let kinds = recordedKinds(ReorderableList([Line(id: 1), Line(id: 2)], onReorder: { _ in }) { _ in Text("One") }.qaName("phases-list"), height: 120)
        XCTAssertTrue(kinds.contains("open_hand phases-list"), "\(kinds)")
    }

    func testTheQaCursorModifierRecordsEveryKindItIsGiven() {
        for kind in QACursorReport.Kind.allCases {
            let report = report(Color.clear.qaCursor(kind).qaName("probe-\(kind.rawValue)"), held: nil)
            XCTAssertEqual(report.cursor, kind)
            XCTAssertEqual(report.element, "probe-\(kind.rawValue)")
        }
    }

    func testAViewOutsideANamedElementRecordsItsCursorWithNoElement() {
        let report = report(Color.clear.qaCursor(.crosshair))
        XCTAssertEqual(report.cursor, .crosshair)
        XCTAssertNil(report.element)
        XCTAssertEqual(report.source, .recorded)
    }

    // MARK: - which recorded place applies at the pointer

    func testTheSmallestViewUnderThePointerWinsAndOnlyInTheWindowInFront() {
        let views = (0..<3).map { _ in NSView() }
        let frames: [ObjectIdentifier: QAElementReport.Rect] = [
            ObjectIdentifier(views[0]): .init(x: 0, y: 0, w: 400, h: 400),
            ObjectIdentifier(views[1]): .init(x: 10, y: 10, w: 50, h: 20),
            ObjectIdentifier(views[2]): .init(x: 300, y: 300, w: 10, h: 10),
        ]
        var front: Int? = 1
        let placed = QACursorRecorder(
            writer: QACursorReportWriter(file: file), pid: 9,
            locate: { frames[ObjectIdentifier($0)].map { .init(shown: $0, window: 1) } },
            pointer: { .init(x: 20, y: 15) }, windowAt: { _ in front }, appCursor: { nil }
        )
        placed.register(views[0], kind: .pointingHand, element: "row")
        placed.register(views[1], kind: .iBeam, element: "field")
        placed.register(views[2], kind: .openHand, element: "handle")

        XCTAssertEqual(placed.report().element, "field")
        XCTAssertEqual(placed.recorded(at: .init(x: 200, y: 200))?.element, "row")
        XCTAssertEqual(placed.recorded(at: .init(x: 305, y: 305))?.element, "handle")
        XCTAssertNil(placed.recorded(at: .init(x: 500, y: 500)))

        placed.register(views[1], kind: nil, element: "field")
        XCTAssertEqual(placed.report().element, "row", "a place that sets no cursor now gives way")
        placed.unregister(views[0])
        XCTAssertNil(placed.report().recorded)

        front = 2
        XCTAssertNil(placed.recorded(at: .init(x: 305, y: 305)), "another window is in front there")
        withExtendedLifetime(views) {}
    }

    func testOfTwoViewsTheSameSizeTheLastRegisteredWins() {
        let views = [NSView(), NSView()]
        let placed = QACursorRecorder(
            writer: QACursorReportWriter(file: file), pid: 9,
            locate: { _ in .init(shown: .init(x: 0, y: 0, w: 10, h: 10), window: 1) },
            pointer: { .init(x: 5, y: 5) }, windowAt: { _ in nil }, appCursor: { nil }
        )
        placed.register(views[0], kind: .pointingHand, element: "first")
        placed.register(views[1], kind: .iBeam, element: "second")
        XCTAssertEqual(placed.report().element, "second")
        placed.register(views[0], kind: .pointingHand, element: "first")
        XCTAssertEqual(placed.report().element, "second", "registering the same again changes nothing")
        placed.register(views[0], kind: .openHand, element: "first")
        XCTAssertEqual(placed.report().element, "first")
        withExtendedLifetime(views) {}
    }

    func testAViewThatWentAwayIsForgotten() {
        let placed = QACursorRecorder(
            writer: QACursorReportWriter(file: file), pid: 9,
            locate: { _ in .init(shown: .init(x: 0, y: 0, w: 10, h: 10), window: 1) },
            pointer: { .init(x: 5, y: 5) }, windowAt: { _ in nil }, appCursor: { nil }
        )
        autoreleasepool {
            let view = NSView()
            placed.register(view, kind: .pointingHand, element: "gone")
        }
        XCTAssertNil(placed.report().recorded)
    }

    // MARK: - c5: a cursor set outside the recorded places

    func testACursorTheAppHoldsThatNoRecordedPlaceSetIsReportedAsUnrecorded() {
        let plain = report(Color.clear, held: "resize_left_right")
        XCTAssertEqual(plain.cursor, .resizeLeftRight)
        XCTAssertNil(plain.element)
        XCTAssertEqual(plain.source, .unrecorded)
        XCTAssertEqual(plain.appCursor, "resize_left_right")

        let overButton = report(
            Button("Open") {}.buttonStyle(.plainPointer).frame(maxWidth: .infinity, maxHeight: .infinity).qaName("open-button"),
            held: "i_beam"
        )
        XCTAssertEqual(overButton.cursor, .iBeam)
        XCTAssertEqual(overButton.source, .unrecorded)
        XCTAssertEqual(overButton.recorded?.element, "open-button")
    }

    func testTheAppHoldingTheRecordedCursorOrAnUnnamedOneKeepsTheRecord() {
        let same = report(Color.clear.qaCursor(.pointingHand).qaName("link"), held: "pointing_hand")
        XCTAssertEqual(same.source, .recorded)
        let unnamed = report(Color.clear.qaCursor(.pointingHand).qaName("link"), held: "unnamed")
        XCTAssertEqual(unnamed.source, .recorded)
        XCTAssertEqual(unnamed.appCursor, "unnamed")
        let none = report(Color.clear, held: "unnamed")
        XCTAssertEqual(none.source, QACursorReport.Source.none)
        XCTAssertEqual(none.cursor, .arrow)
    }

    func testTheAppsCursorIsNamedByIdentityNeverByImage() {
        XCTAssertEqual(QACursorRecorder.name(of: .pointingHand), "pointing_hand")
        XCTAssertEqual(QACursorRecorder.name(of: .iBeam), "i_beam")
        XCTAssertEqual(QACursorRecorder.name(of: .arrow), "arrow")
        XCTAssertEqual(QACursorRecorder.name(of: NSCursor(image: NSCursor.arrow.image, hotSpot: .zero)), "unnamed")
        XCTAssertNil(QACursorRecorder.name(of: nil))
    }

    // MARK: - the file

    func testSampleWritesTheReportUnderTheQARootOnlyWhenItChanges() throws {
        var held = "arrow"
        let recorder = QACursorRecorder(
            writer: QACursorReportWriter(file: file), pid: 9, locate: { _ in nil },
            pointer: { .init(x: 12, y: 34) }, windowAt: { _ in nil }, appCursor: { held }
        )
        recorder.sample()
        let first = try QACursorReport.decoded(Data(contentsOf: file))
        XCTAssertEqual(first.cursor, .arrow)
        XCTAssertEqual(first.source, QACursorReport.Source.none)
        XCTAssertEqual(first.pointer, .init(x: 12, y: 34))
        XCTAssertEqual(first.pid, 9)

        try FileManager.default.removeItem(at: file)
        recorder.sample()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "the same report is not written again")

        held = "open_hand"
        recorder.sample()
        XCTAssertEqual(try QACursorReport.decoded(Data(contentsOf: file)).source, .unrecorded)
    }

    func testAReportThatCannotBeWrittenIsLoggedAndDropped() throws {
        let blocked = root.appendingPathComponent("blocked")
        try Data().write(to: blocked)
        let recorder = QACursorRecorder(
            writer: QACursorReportWriter(file: blocked.appendingPathComponent("9.json")), pid: 9, locate: { _ in nil },
            pointer: { .init(x: 0, y: 0) }, windowAt: { _ in nil }, appCursor: { nil }
        )
        recorder.sample()
        XCTAssertFalse(FileManager.default.fileExists(atPath: blocked.appendingPathComponent("9.json").path))
    }

    // MARK: - c2: nothing without QA mode

    func testWithoutQAModeNothingIsRecordedAndNoFileIsWritten() {
        QACursorRecorder.start(qaMode: nil)
        XCTAssertNil(QACursorRecorder.current)
        let host = hosted(
            Button("Open") {}.buttonStyle(.plainPointer).qaName("open-button")
                .overlay(DirectorTextField(nil, text: .constant("")).qaName("name-field"))
        )
        XCTAssertTrue(probes(in: host).isEmpty, "no probe views outside QA mode")
        QACursorRecorder.record(NSView(), kind: .pointingHand, element: "chip")
        XCTAssertNil(QACursorRecorder.current)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(QAMode.cursorFolder).path))
    }

    func testStartInQAModeWritesTheFirstReportThenEachChange() throws {
        var held = "arrow"
        let make: (QACursorReportWriter, Int32) -> QACursorRecorder = { writer, pid in
            QACursorRecorder(writer: writer, pid: pid, locate: { _ in nil }, pointer: { .init(x: 1, y: 2) }, windowAt: { _ in nil }, appCursor: { held })
        }
        QACursorRecorder.start(qaMode: QAMode(root: root), pid: 9, make: make)
        let recorder = try XCTUnwrap(QACursorRecorder.current)
        QACursorRecorder.start(qaMode: QAMode(root: root), pid: 9, make: make)
        XCTAssertTrue(QACursorRecorder.current === recorder, "a second start keeps the first recorder")
        let report = try QACursorReport.decoded(Data(contentsOf: file))
        XCTAssertEqual(report.pid, 9)
        XCTAssertEqual(report.version, QACursorReport.version)
        XCTAssertEqual(report.cursor, .arrow)

        held = "closed_hand"
        let written = expectation(description: "the timer writes the change")
        let deadline = Date().addingTimeInterval(3)
        func poll() {
            if (try? QACursorReport.decoded(Data(contentsOf: file)))?.cursor == .closedHand { return written.fulfill() }
            if Date() < deadline { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { poll() } }
        }
        poll()
        wait(for: [written], timeout: 4)
    }

    func testOnScreenIsNilForAViewInNoWindow() {
        XCTAssertNil(QACursorRecorder.onScreen(NSView()))
    }
}
