import AppKit
import SwiftUI
import SymphonyBarCore

/// Records the named elements on screen for QA mode's element report (TP-1677). The app makes one at a QA launch
/// (`start(qaMode:)`); without it, `qaName` and `qaPart` set the accessibility identifier and record nothing, so a
/// normal launch keeps no frames and writes no file.
///
/// Each named element and part carries an empty AppKit view as its background, as the queue row's test probes do:
/// at write time the view says where it is on screen, scrolled or not, so the report holds the frames the window
/// draws.
@MainActor
public final class QAElementRecorder {
    /// The recorder of a QA launch, nil otherwise.
    public private(set) static var current: QAElementRecorder?

    struct Entry {
        let element: String
        let part: String?
        weak var view: NSView?
        var selected: Bool
        var focused: Bool
    }

    /// Where a view is: its frame, whether any of it shows, and its window; nil when it is in no window.
    struct Location {
        let frame: QAElementReport.Rect
        let visible: Bool
        let window: QAElementReport.Window
    }

    private let writer: QAElementReportWriter
    private let pid: Int32
    private let now: () -> Date
    private let locate: (NSView) -> Location?
    private var entries: [ObjectIdentifier: Entry] = [:]
    private(set) var state = QAElementReport.State()

    init(
        writer: QAElementReportWriter, pid: Int32, now: @escaping () -> Date = Date.init,
        locate: @escaping (NSView) -> Location? = QAElementRecorder.onScreen
    ) {
        self.writer = writer
        self.pid = pid
        self.now = now
        self.locate = locate
    }

    /// Starts recording for a QA launch: the report goes to `qaMode.elementsReport(pid:)`. Nothing without QA mode.
    public static func start(qaMode: QAMode?, pid: Int32 = getpid()) {
        guard current == nil, let qaMode else { return }
        let recorder = QAElementRecorder(writer: QAElementReportWriter(file: qaMode.elementsReport(pid: pid)), pid: pid)
        current = recorder
        recorder.changed()
    }

    /// Makes `recorder` the current one, or none; for tests.
    static func use(_ recorder: QAElementRecorder?) { current = recorder }

    /// The window's page and the ticket open over it, as the window holds them.
    public func setPage(_ page: SymphonyView?, ticket: String?) {
        let next = QAElementReport.State(page: page?.rawValue, pageTitle: page?.title, ticket: ticket)
        guard next.page != state.page || next.ticket != state.ticket else { return }
        state.page = next.page
        state.pageTitle = next.pageTitle
        state.ticket = next.ticket
        changed()
    }

    func register(_ view: NSView, element: String, part: String?, selected: Bool, focused: Bool) {
        entries[ObjectIdentifier(view)] = Entry(element: element, part: part, view: view, selected: selected, focused: focused)
        changed()
    }

    func unregister(_ view: NSView) {
        guard entries.removeValue(forKey: ObjectIdentifier(view)) != nil else { return }
        changed()
    }

    /// Something moved or changed: the report is written again shortly.
    func changed() {
        writer.schedule { [weak self] in
            MainActor.assumeIsolated { self?.report() ?? QAElementReport(at: Date(), pid: 0, windows: [], state: .init(), elements: []) }
        }
    }

    /// The report as the screen is now.
    func report() -> QAElementReport {
        var elements: [String: QAElementReport.Element] = [:]
        var parts: [(String, String, QAElementReport.Rect)] = []
        var windows: [Int: QAElementReport.Window] = [:]

        for entry in entries.values {
            guard let view = entry.view, let location = locate(view) else { continue }
            if let part = entry.part {
                parts.append((entry.element, part, location.frame))
                continue
            }
            windows[location.window.number] = location.window
            elements[entry.element] = QAElementReport.Element(
                name: entry.element, frame: location.frame, visible: location.visible, window: location.window.number,
                selected: entry.selected, focused: entry.focused, parts: [:]
            )
        }
        for (element, part, frame) in parts { elements[element]?.parts[part] = frame }

        let sorted = elements.values.sorted { ($0.frame.y, $0.frame.x, $0.name) < ($1.frame.y, $1.frame.x, $1.name) }
        var state = state
        state.selected = sorted.filter(\.selected).map(\.name)
        state.focused = sorted.filter(\.focused).map(\.name)
        return QAElementReport(
            at: now(), pid: pid, windows: windows.values.sorted { $0.number < $1.number }, state: state, elements: sorted
        )
    }

    /// Where `view` is on screen, nil when it is in no window.
    static func onScreen(_ view: NSView) -> Location? {
        guard let window = view.window else { return nil }
        let height = mainDisplayHeight()
        return Location(
            frame: screenRect(window.convertToScreen(view.convert(view.bounds, to: nil)), mainHeight: height),
            visible: window.isVisible && !view.visibleRect.isEmpty,
            window: QAElementReport.Window(
                number: window.windowNumber, title: window.title, frame: screenRect(window.frame, mainHeight: height),
                key: window.isKeyWindow
            )
        )
    }

    /// The main display's height, which flips AppKit's bottom-left screen points to the top-left ones QA uses.
    static func mainDisplayHeight() -> Double {
        Double(NSScreen.screens.first?.frame.maxY ?? 0)
    }

    /// `rect` in AppKit screen points (from the bottom left) as QA's: from the main display's top left.
    static func screenRect(_ rect: NSRect, mainHeight: Double) -> QAElementReport.Rect {
        QAElementReport.Rect(x: rect.minX, y: mainHeight - rect.maxY, w: rect.width, h: rect.height)
    }
}

extension EnvironmentValues {
    /// The named element the views inside belong to, for their `qaPart`.
    @Entry var qaElementName: String? = nil
}

extension View {
    /// Gives this element its stable QA name (`QAElementNames`), which is also its accessibility identifier. In QA mode
    /// the element report lists it with its frame and its parts' (`qaPart`), and says whether it is `selected` or
    /// `focused`. Call it where the element is made, after `accessibilityElement`.
    public func qaName(_ name: String, selected: Bool = false, focused: Bool = false) -> some View {
        accessibilityIdentifier(name)
            .modifier(QANameRecording(element: name, part: nil, selected: selected, focused: focused))
            .environment(\.qaElementName, name)
    }

    /// Names a part of the element named around it (a row's `title`): QA mode's report gives its frame under the
    /// element, so a session measures inside the element. Nothing outside QA mode or outside a named element.
    public func qaPart(_ part: String) -> some View {
        modifier(QAPartRecording(part: part))
    }
}

private struct QAPartRecording: ViewModifier {
    let part: String
    @Environment(\.qaElementName) private var element

    func body(content: Content) -> some View {
        if let element {
            content.modifier(QANameRecording(element: element, part: part, selected: false, focused: false))
        } else {
            content
        }
    }
}

private struct QANameRecording: ViewModifier {
    let element: String
    let part: String?
    let selected: Bool
    let focused: Bool

    func body(content: Content) -> some View {
        if let recorder = QAElementRecorder.current {
            content
                .background(
                    QAProbe(recorder: recorder, element: element, part: part, selected: selected, focused: focused)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                )
                // A scroll moves the element on screen without changing its view's frame in its parent.
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { _ in recorder.changed() }
        } else {
            content
        }
    }
}

/// The empty view whose place on screen is the element's.
private struct QAProbe: NSViewRepresentable {
    let recorder: QAElementRecorder
    let element: String
    let part: String?
    let selected: Bool
    let focused: Bool

    func makeNSView(context _: Context) -> QAProbeView {
        let view = QAProbeView()
        view.recorder = recorder
        return view
    }

    func updateNSView(_ view: QAProbeView, context _: Context) {
        recorder.register(view, element: element, part: part, selected: selected, focused: focused)
    }

    static func dismantleNSView(_ view: QAProbeView, coordinator _: ()) {
        view.recorder?.unregister(view)
    }
}

final class QAProbeView: NSView {
    weak var recorder: QAElementRecorder?

    override func hitTest(_: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        recorder?.changed()
    }
}
