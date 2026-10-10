import AppKit
import SwiftUI
import SymphonyBarCore

/// D4: one ticket's run transcript, read from the transcript endpoint while its window is open.
@MainActor
final class TranscriptModel: ObservableObject {
    /// The transcript is read again this often while the window is open, so a live run's last call stays current.
    static let interval: TimeInterval = 5

    let identifier: String
    let repoKey: String?
    private let client: LiveAPIClient
    /// The time silence is measured against: the state's own, so it agrees with the ticket page.
    private let reference: () -> Date

    @Published private(set) var transcript: Transcript?
    /// What the last read got when it got no transcript.
    @Published private(set) var result: EndpointResult?
    @Published var filter: Transcript.Filter = .all
    @Published var query = ""
    @Published var selection: Int?
    private var task: Task<Void, Never>?

    init(identifier: String, repoKey: String?, client: LiveAPIClient, reference: @escaping () -> Date) {
        self.identifier = identifier
        self.repoKey = repoKey
        self.client = client
        self.reference = reference
    }

    /// Reads now and then every `interval` until `stop()`.
    func start() {
        task?.cancel()
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.read()
                try? await Task.sleep(for: .seconds(Self.interval))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    func read() async {
        let answer = await client.get(TicketPage.transcriptPath(identifier, repoKey: repoKey))
        if case let .loaded(data) = answer, let transcript = Transcript.decode(data, reference: reference()) {
            self.transcript = transcript
            result = nil
        } else {
            result = answer
        }
    }

    func copySessionID() {
        guard let id = transcript?.sessionID else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(id, forType: .string)
    }
}

/// The transcript window's content: the transcript, or why there is none.
struct TranscriptContent: View {
    @ObservedObject var model: TranscriptModel

    var body: some View {
        Group {
            if let transcript = model.transcript {
                TranscriptView(
                    transcript: transcript,
                    filter: $model.filter,
                    query: $model.query,
                    selection: $model.selection,
                    copySessionID: model.copySessionID
                )
            } else if case .unsupported = model.result {
                EmptyState(title: "Symphony no longer keeps a transcript for \(model.identifier).", symbol: "text.page.slash")
            } else if case let .failed(message) = model.result {
                EmptyState(title: message, symbol: DesignTokens.Status.problem.symbol)
            } else {
                EmptyState(title: "Reading the transcript…", symbol: "text.page", showsSpinner: true)
            }
        }
        .frame(minWidth: 640, minHeight: 420)
        .background(DesignTokens.Surface.window.color)
    }
}

/// The filters, search and Copy Session ID above the turns, and the selected event in full below them.
struct TranscriptView: View {
    let transcript: Transcript
    @Binding var filter: Transcript.Filter
    @Binding var query: String
    @Binding var selection: Int?
    let copySessionID: () -> Void
    @FocusState private var searchFocused: Bool

    var body: some View {
        let turns = transcript.turns(filter: filter, query: query)
        VStack(spacing: 0) {
            TranscriptBar(filter: $filter, query: $query, searchFocused: $searchFocused, transcript: transcript, copySessionID: copySessionID)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    TranscriptTurns(turns: turns, empty: transcript.isEmpty, selection: $selection)
                }
                .onAppear { proxy.scrollTo(turns.last?.items.last?.id, anchor: .bottom) }
            }
            .frame(maxHeight: .infinity)
            Divider()
            TranscriptDetail(item: turns.flatMap(\.items).first { $0.id == selection } ?? transcript.items.first { $0.id == selection })
                .frame(height: 200)
        }
        // ⌘F searches the transcript (P10).
        .background(
            // Drawn at no size rather than hidden, so its shortcut stays registered.
            Button("Search") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        )
    }
}

/// All / Messages / Tools / Errors, the search field and Copy Session ID.
struct TranscriptBar: View {
    @Binding var filter: Transcript.Filter
    @Binding var query: String
    var searchFocused: FocusState<Bool>.Binding
    let transcript: Transcript
    let copySessionID: () -> Void

    var body: some View {
        HStack(spacing: DesignTokens.Space.s3) {
            Picker("Show", selection: $filter) {
                ForEach(Transcript.Filter.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            TextField(Transcript.searchPrompt, text: $query)
                .textFieldStyle(.roundedBorder)
                .focused(searchFocused)
                .frame(minWidth: 160, maxWidth: 260)
                .help("Search (⌘F)")
            Spacer(minLength: 0)
            Button(Transcript.copySessionIDTitle, action: copySessionID)
                .disabled(transcript.sessionID == nil)
                .help(transcript.sessionID ?? "No session yet")
        }
        .padding(.horizontal, DesignTokens.Space.s4)
        .padding(.vertical, DesignTokens.Space.s2)
    }
}

/// The turns and their rows, outside the scroll view so they also render offscreen.
struct TranscriptTurns: View {
    let turns: [Transcript.Turn]
    /// The transcript has no events at all, rather than none that match.
    let empty: Bool
    @Binding var selection: Int?

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            if turns.isEmpty {
                Text(empty ? "No events yet." : "No events match.")
                    .font(DesignTokens.TypeStyle.body.font)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(DesignTokens.Space.s6)
            }
            ForEach(turns) { turn in
                HStack(spacing: DesignTokens.Space.s2) {
                    Text(turn.title).font(DesignTokens.TypeStyle.label.font)
                    if !turn.ended {
                        Text("under way").font(DesignTokens.TypeStyle.caption.font).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, DesignTokens.Space.s4)
                .padding(.top, DesignTokens.Space.s3)
                .padding(.bottom, DesignTokens.Space.s1)
                .accessibilityAddTraits(.isHeader)
                ForEach(turn.items) { item in
                    TranscriptRow(item: item, selected: item.id == selection)
                        .id(item.id)
                        .contentShape(Rectangle())
                        .onTapGesture { selection = item.id }
                        .accessibilityAddTraits(item.id == selection ? [.isSelected, .isButton] : .isButton)
                        .accessibilityAction { selection = item.id }
                }
            }
        }
        .padding(.bottom, DesignTokens.Space.s3)
    }
}

/// A row: time, kind symbol, title and one line, and its duration or how long it has been silent.
struct TranscriptRow: View {
    let item: Transcript.Item
    let selected: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.s3) {
            Text(item.timeText ?? "")
                .font(DesignTokens.TypeStyle.mono.font)
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .frame(width: 16)
                .accessibilityHidden(true)
            Text(item.title)
                .font(DesignTokens.TypeStyle.rowTitle.font)
                .lineLimit(1)
                .fixedSize()
            Text(item.kind == .toolCall && item.summary.hasPrefix(item.title + " ") ? String(item.summary.dropFirst(item.title.count + 1)) : item.summary)
                .font(item.kind == .toolCall ? DesignTokens.TypeStyle.mono.font : DesignTokens.TypeStyle.body.font)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: DesignTokens.Space.s2)
            if let trailing = item.trailing {
                Text(trailing)
                    .font(DesignTokens.TypeStyle.callout.font)
                    .monospacedDigit()
                    .foregroundStyle(item.silentSeconds != nil ? AnyShapeStyle(DesignTokens.Status.you.tint) : AnyShapeStyle(.secondary))
                    .fixedSize()
            }
        }
        .padding(.horizontal, DesignTokens.Space.s4)
        .padding(.vertical, DesignTokens.Space.s1 + 2)
        .background(selected ? AnyShapeStyle(DesignTokens.SystemColor.accent.color.opacity(0.18)) : AnyShapeStyle(.clear))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.accessibilityLabel)
    }

    private var symbol: String {
        switch item.kind {
        case .message: "text.bubble"
        case .toolCall: item.result == nil ? "hourglass" : "wrench.and.screwdriver"
        case .error: DesignTokens.Status.problem.symbol
        case .event: "info.circle"
        }
    }

    private var tint: Color {
        switch item.kind {
        case .message: DesignTokens.SystemColor.accent.color
        case .toolCall: item.result == nil ? DesignTokens.Status.you.tint : .secondary
        case .error: DesignTokens.Status.problem.tint
        case .event: .secondary
        }
    }
}

/// The selected event in full, monospaced and selectable.
struct TranscriptDetail: View {
    let item: Transcript.Item?

    var body: some View {
        ScrollView {
            Group {
                if let item {
                    VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
                        Text([item.timeText, item.title, item.trailing].compactMap { $0 }.joined(separator: " · "))
                            .font(DesignTokens.TypeStyle.label.font)
                            .foregroundStyle(.secondary)
                        Text(item.detail)
                            .font(DesignTokens.TypeStyle.mono.font)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text("Select an event to see it in full.")
                        .font(DesignTokens.TypeStyle.body.font)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DesignTokens.Space.s4)
        }
        .background(DesignTokens.Surface.content.color)
    }
}

/// The transcript windows: one per ticket, and another beside it on ⌘-click (D4).
@MainActor
final class TranscriptWindows: NSObject, NSWindowDelegate {
    private let client: LiveAPIClient
    /// The time silence is measured against.
    var reference: () -> Date = Date.init
    private var windows: [(identifier: String, window: NSWindow, model: TranscriptModel)] = []

    init(client: LiveAPIClient) {
        self.client = client
    }

    /// Brings the ticket's transcript window to the front, or opens one; `newWindow` always opens another.
    func open(identifier: String, repoKey: String?, newWindow: Bool) {
        if !newWindow, let open = windows.last(where: { $0.identifier == identifier }) {
            open.window.makeKeyAndOrderFront(nil)
            return
        }
        let model = TranscriptModel(identifier: identifier, repoKey: repoKey, client: client, reference: { [weak self] in self?.reference() ?? Date() })
        let hostingController = NSHostingController(rootView: TranscriptContent(model: model))
        hostingController.sizingOptions = [.minSize]
        let window = NSWindow(contentViewController: hostingController)
        window.title = "\(identifier) · Transcript"
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.setContentSize(NSSize(width: 820, height: 640))
        window.isReleasedWhenClosed = false
        window.delegate = self
        if let last = windows.last?.window {
            window.setFrameTopLeftPoint(window.cascadeTopLeft(from: NSPoint(x: last.frame.minX, y: last.frame.maxY)))
        } else {
            window.center()
        }
        windows.append((identifier, window, model))
        model.start()
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, let index = windows.firstIndex(where: { $0.window === window }) else { return }
        windows[index].model.stop()
        windows.remove(at: index)
    }
}
