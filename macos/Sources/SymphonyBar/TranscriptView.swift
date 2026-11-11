import AppKit
import SwiftUI
import SymphonyBarCore
import SymphonyBarUI

/// D4 (TP-1452): the session reader of one run, opened from its Run group's More as "Read the whole session". It
/// reads each step's transcript once, through its own `StepTranscripts`, and while the run works follows it as the
/// ticket page has it, so the run now's newest lines come in here too.
@MainActor
final class SessionReaderModel: ObservableObject {
    /// The run is read again from the page this often while the window is open, the page's own cadence.
    static let interval: TimeInterval = 5

    let identifier: String
    @Published private(set) var run: RunGroupModel
    /// The lines a person expanded.
    @Published var expanded: Set<String> = []
    let transcripts: StepTranscripts
    /// The run as the page has it now; nil once the page shows another ticket, and the reader keeps what it has.
    private let follow: () -> RunGroupModel?
    private var task: Task<Void, Never>?

    init(identifier: String, run: RunGroupModel, transcripts: StepTranscripts, follow: @escaping () -> RunGroupModel?) {
        self.identifier = identifier
        self.run = run
        self.transcripts = transcripts
        self.follow = follow
    }

    var reader: SessionReader {
        SessionReader.build(identifier: identifier, run: run) { [transcripts] in transcripts.lines($0) }
    }

    /// Reads every step's transcript, then follows a running run every `interval` until `stop()`.
    func start() {
        load()
        task?.cancel()
        guard run.isLive else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.interval))
                guard let self, !Task.isCancelled else { return }
                if !refresh() { return }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// Takes the run as the page has it now and reads any transcript it gained; false once it no longer runs.
    @discardableResult
    func refresh() -> Bool {
        if let latest = follow() { run = latest }
        load()
        return run.isLive
    }

    private func load() {
        for transcript in run.steps.compactMap(\.transcript) { transcripts.load(transcript) }
    }
}

/// The reader window's content, drawing again as the run and its transcripts come in.
struct SessionReaderContent: View {
    @ObservedObject var model: SessionReaderModel
    @ObservedObject var transcripts: StepTranscripts

    init(model: SessionReaderModel) {
        self.model = model
        transcripts = model.transcripts
    }

    var body: some View {
        SessionReaderView(reader: model.reader, expanded: $model.expanded)
            .frame(minWidth: 640, minHeight: 420)
    }
}

/// The session readers: one per run, brought to the front when it is open already; they stay open after the main
/// window closes.
@MainActor
final class SessionReaderWindows: NSObject, NSWindowDelegate {
    private let client: LiveAPIClient
    private var windows: [(runID: String, window: NSWindow, model: SessionReaderModel)] = []

    init(client: LiveAPIClient) {
        self.client = client
    }

    /// Brings `run`'s reader to the front, or opens one on it.
    func open(identifier: String, run: RunGroupModel, follow: @escaping () -> RunGroupModel?) {
        if let open = windows.last(where: { $0.runID == run.id }) {
            open.window.makeKeyAndOrderFront(nil)
            return
        }
        let transcripts = StepTranscripts(get: { [client] path in await client.answer(path) })
        let model = SessionReaderModel(identifier: identifier, run: run, transcripts: transcripts, follow: follow)
        let hostingController = NSHostingController(
            rootView: SessionReaderContent(model: model).environment(\.openURL, URLOpener.action)
        )
        hostingController.sizingOptions = [.minSize]
        let window = NSWindow(contentViewController: hostingController)
        window.title = model.reader.windowTitle
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.setContentSize(NSSize(width: 820, height: 640))
        window.isReleasedWhenClosed = false
        window.delegate = self
        if let last = windows.last?.window {
            window.setFrameTopLeftPoint(window.cascadeTopLeft(from: NSPoint(x: last.frame.minX, y: last.frame.maxY)))
        } else {
            window.center()
        }
        windows.append((run.id, window, model))
        model.start()
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, let index = windows.firstIndex(where: { $0.window === window }) else { return }
        windows[index].model.stop()
        windows.remove(at: index)
    }
}
