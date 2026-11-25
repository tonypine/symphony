import AppKit
import SwiftUI
import SymphonyBarCore

/// Records the cursor each place of the app sets, for QA mode's cursor report (TP-1678). The app makes one at a QA
/// launch (`start(qaMode:)`); without it `qaCursor` adds nothing and `record` does nothing, so a normal launch keeps
/// no cursor and writes no file.
///
/// Every place that sets a cursor registers its view with the kind it sets there and the named element around it
/// (`qaName`, `qaSection`): the shared button pointer, the text fields, the chips and links of a chip text, the reorder
/// grab and the not-allowed pointer. A few times a second the recorder looks at the pointer: the smallest registered
/// view under it, in the window in front there, is what a recorded place set. It also names the cursor the app holds
/// (`NSCursor.current`) by identity with the system's named cursors, never by image, so a cursor set outside the
/// recorded places shows in the report as such.
@MainActor
public final class QACursorRecorder {
    /// The recorder of a QA launch, nil otherwise.
    public private(set) static var current: QACursorRecorder?

    /// How often the recorder looks at the pointer and the cursor.
    static let interval: TimeInterval = 0.1

    struct Entry {
        weak var view: NSView?
        var kind: QACursorReport.Kind?
        var element: String?
        var order: Int
    }

    /// Where a view is on screen: the part of it that shows and its window's number; nil when it is in no window or
    /// none of it shows.
    struct Location {
        let shown: QAElementReport.Rect
        let window: Int
    }

    private let writer: QACursorReportWriter
    private let pid: Int32
    private let now: () -> Date
    private let locate: @MainActor (NSView) -> Location?
    private let pointer: @MainActor () -> QACursorReport.Point
    private let windowAt: @MainActor (QACursorReport.Point) -> Int?
    private let appCursor: @MainActor () -> String?
    private var entries: [ObjectIdentifier: Entry] = [:]
    private var registrations = 0
    private var timer: Timer?

    init(
        writer: QACursorReportWriter, pid: Int32, now: @escaping () -> Date = Date.init,
        locate: @escaping @MainActor (NSView) -> Location? = QACursorRecorder.onScreen,
        pointer: @escaping @MainActor () -> QACursorReport.Point = QACursorRecorder.mouseLocation,
        windowAt: @escaping @MainActor (QACursorReport.Point) -> Int? = QACursorRecorder.windowNumber(at:),
        appCursor: @escaping @MainActor () -> String? = { QACursorRecorder.name(of: NSCursor.current) }
    ) {
        self.writer = writer
        self.pid = pid
        self.now = now
        self.locate = locate
        self.pointer = pointer
        self.windowAt = windowAt
        self.appCursor = appCursor
    }

    /// Starts recording for a QA launch: the report goes to `qaMode.cursorReport(pid:)`, written now and then whenever
    /// what it says changes. Nothing without QA mode.
    public static func start(qaMode: QAMode?, pid: Int32 = getpid()) {
        start(qaMode: qaMode, pid: pid) { QACursorRecorder(writer: $0, pid: $1) }
    }

    static func start(qaMode: QAMode?, pid: Int32, make: (QACursorReportWriter, Int32) -> QACursorRecorder) {
        guard current == nil, let qaMode else { return }
        let recorder = make(QACursorReportWriter(file: qaMode.cursorReport(pid: pid)), pid)
        current = recorder
        recorder.sample()
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated { QACursorRecorder.current?.sample() }
        }
        RunLoop.main.add(timer, forMode: .common)
        recorder.timer = timer
    }

    /// Makes `recorder` the current one, or none; for tests.
    static func use(_ recorder: QACursorRecorder?) {
        current?.timer?.invalidate()
        current = recorder
    }

    /// Records that `view` sets `kind` over itself for the named `element`, or no cursor for nil. What an AppKit view
    /// that sets its own cursor calls; a SwiftUI view uses `qaCursor`.
    public static func record(_ view: NSView, kind: QACursorReport.Kind?, element: String?) {
        current?.register(view, kind: kind, element: element)
    }

    func register(_ view: NSView, kind: QACursorReport.Kind?, element: String?) {
        let key = ObjectIdentifier(view)
        if let entry = entries[key], entry.view === view, entry.kind == kind, entry.element == element { return }
        registrations += 1
        entries[key] = Entry(view: view, kind: kind, element: element, order: registrations)
    }

    func unregister(_ view: NSView) {
        entries.removeValue(forKey: ObjectIdentifier(view))
    }

    /// Writes the report when what it says changed.
    func sample() {
        do {
            try writer.write(report())
        } catch {
            NSLog("Symphony QA: couldn't write \(writer.file.path): \(error.localizedDescription)")
        }
    }

    /// The report as the pointer and the app's cursor are now.
    func report() -> QACursorReport {
        let point = pointer()
        return QACursorReport(at: now(), pid: pid, pointer: point, recorded: recorded(at: point), appCursor: appCursor())
    }

    /// What the recorded places set at `point`: the smallest view under it that sets a cursor, in the window in front
    /// there; the last one registered of two the same size.
    func recorded(at point: QACursorReport.Point) -> QACursorReport.Recorded? {
        let front = windowAt(point)
        entries = entries.filter { $0.value.view != nil }
        let covering = entries.values.compactMap { entry -> (Entry, QACursorReport.Kind, Location)? in
            guard let view = entry.view, let kind = entry.kind, let location = locate(view) else { return nil }
            guard Self.holds(location.shown, point), front == nil || front == location.window else { return nil }
            return (entry, kind, location)
        }
        let smallest = covering.min { a, b in
            let areaA = a.2.shown.w * a.2.shown.h, areaB = b.2.shown.w * b.2.shown.h
            return areaA != areaB ? areaA < areaB : a.0.order > b.0.order
        }
        return smallest.map { QACursorReport.Recorded(cursor: $0.1, element: $0.0.element, frame: $0.2.shown) }
    }

    /// Whether `rect` holds `point`.
    static func holds(_ rect: QAElementReport.Rect, _ point: QACursorReport.Point) -> Bool {
        point.x >= rect.x && point.x < rect.x + rect.w && point.y >= rect.y && point.y < rect.y + rect.h
    }

    /// The system's named cursors, by the names the report gives them.
    static var namedCursors: [(QACursorReport.Kind, NSCursor)] {
        [
            (.arrow, .arrow), (.pointingHand, .pointingHand), (.iBeam, .iBeam),
            (.verticalIBeam, .iBeamCursorForVerticalLayout), (.openHand, .openHand), (.closedHand, .closedHand),
            (.operationNotAllowed, .operationNotAllowed), (.crosshair, .crosshair), (.contextualMenu, .contextualMenu),
            (.dragCopy, .dragCopy), (.dragLink, .dragLink), (.disappearingItem, .disappearingItem),
            (.resizeLeftRight, .resizeLeftRight), (.resizeUpDown, .resizeUpDown),
        ]
    }

    /// The name of `cursor` by identity with the system's named cursors, `unnamed` for another one, nil for none.
    static func name(of cursor: NSCursor?) -> String? {
        guard let cursor else { return nil }
        return namedCursors.first { $0.1 === cursor }?.0.rawValue ?? "unnamed"
    }

    /// Where `view` shows on screen, nil when it is in no window, its window is hidden or none of it shows.
    static func onScreen(_ view: NSView) -> Location? {
        guard let window = view.window, window.isVisible else { return nil }
        let shown = view.visibleRect
        guard !shown.isEmpty else { return nil }
        let rect = window.convertToScreen(view.convert(shown, to: nil))
        return Location(shown: QAElementRecorder.screenRect(rect, mainHeight: QAElementRecorder.mainDisplayHeight()), window: window.windowNumber)
    }

    /// The pointer in QA's screen points, from the main display's top left.
    static func mouseLocation() -> QACursorReport.Point {
        let location = NSEvent.mouseLocation
        return QACursorReport.Point(x: location.x, y: QAElementRecorder.mainDisplayHeight() - location.y)
    }

    /// The number of the window in front at `point`, nil when none is.
    static func windowNumber(at point: QACursorReport.Point) -> Int? {
        let location = NSPoint(x: point.x, y: QAElementRecorder.mainDisplayHeight() - point.y)
        let number = NSWindow.windowNumber(at: location, belowWindowWithWindowNumber: 0)
        return number > 0 ? number : nil
    }
}

extension View {
    /// Records, in QA mode only, that this view sets the `kind` cursor over itself (nil: none), for the named element
    /// around it, so `qa_hover` reads the cursor from the app (TP-1678). Nothing outside QA mode. Every place that sets
    /// a cursor calls it next to what sets it: `buttonPointer`, the text fields, the reorder grab.
    public func qaCursor(_ kind: QACursorReport.Kind?) -> some View {
        modifier(QACursorRecording(kind: kind))
    }
}

private struct QACursorRecording: ViewModifier {
    let kind: QACursorReport.Kind?
    @Environment(\.qaElementName) private var element

    func body(content: Content) -> some View {
        if let recorder = QACursorRecorder.current {
            content.background(
                QACursorProbe(recorder: recorder, kind: kind, element: element)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            )
        } else {
            content
        }
    }
}

/// The empty view whose place on screen is where the cursor is set.
private struct QACursorProbe: NSViewRepresentable {
    let recorder: QACursorRecorder
    let kind: QACursorReport.Kind?
    let element: String?

    func makeNSView(context _: Context) -> QACursorProbeView {
        let view = QACursorProbeView()
        view.recorder = recorder
        return view
    }

    func updateNSView(_ view: QACursorProbeView, context _: Context) {
        recorder.register(view, kind: kind, element: element)
    }

    static func dismantleNSView(_ view: QACursorProbeView, coordinator _: ()) {
        view.recorder?.unregister(view)
    }
}

final class QACursorProbeView: NSView {
    weak var recorder: QACursorRecorder?

    override func hitTest(_: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }
}
