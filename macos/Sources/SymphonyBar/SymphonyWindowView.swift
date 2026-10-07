import AppKit
import SwiftUI
import SymphonyBarCore

/// What the Symphony window shows, refreshed by its controller.
@MainActor
final class SymphonyWindowModel: ObservableObject {
    let sidebar = Sidebar()
    let client: LiveAPIClient

    /// The view shown; Repos never is, as it opens its own window.
    @Published var selection: SymphonyView {
        didSet {
            guard selection != oldValue else { return }
            onSelect(selection)
        }
    }

    /// Whether Symphony answers, or which placeholder every view shows instead (D0).
    @Published var state: WindowState = .stopped
    @Published var paused = false
    /// The app's version, for the sidebar footer while Symphony doesn't say its own.
    var appVersion = ""
    /// Where the client reads Symphony from, for Diagnostics.
    var apiURL: () -> URL? = { nil }
    var canOpenWebDashboard: () -> Bool = { false }
    var canOpenLogs: () -> Bool = { false }

    var onSelect: (SymphonyView) -> Void = { _ in }
    var onAction: (WindowState.Action) -> Void = { _ in }
    var onOpenRepos: () -> Void = {}
    var onOpenWebDashboard: () -> Void = {}

    init(client: LiveAPIClient, selection: SymphonyView) {
        self.client = client
        self.selection = selection
    }

    /// Shows `view`: Repos opens its window and the selection stays where it was.
    func show(_ view: SymphonyView) {
        if view.opensOwnWindow {
            onOpenRepos()
        } else {
            selection = view
        }
    }

    /// The sidebar footer's first line: Symphony's state, on its own so the sidebar never cuts it off.
    var footerState: String { state.stateWord(paused: paused) }

    /// The sidebar footer's second line: Symphony and its version.
    var footerVersion: String {
        let version = state == .connected ? client.diagnostics?.build?.version ?? appVersion : appVersion
        return version.isEmpty ? "Symphony" : "Symphony \(version)"
    }

    /// Copies the last state payload to the clipboard.
    func copyStateJSON() {
        guard let text = client.stateJSONText else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// The Symphony window: a sidebar of views, the selected view, and a toolbar with its title, the connection state
/// and Refresh.
struct SymphonyWindowView: View {
    @ObservedObject var model: SymphonyWindowModel
    @ObservedObject var client: LiveAPIClient

    init(model: SymphonyWindowModel) {
        self.model = model
        client = model.client
    }

    var body: some View {
        NavigationSplitView {
            SymphonySidebar(model: model)
                .navigationSplitViewColumnWidth(
                    min: DesignTokens.Layout.minSidebarWidth,
                    ideal: DesignTokens.Layout.sidebarWidth,
                    max: DesignTokens.Layout.maxSidebarWidth
                )
        } detail: {
            SymphonyDetail(model: model, client: client)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(DesignTokens.Surface.window.color)
                .toolbar {
                    ToolbarItem(placement: .navigation) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(model.selection.title).font(.headline)
                            Text(model.selection.subtitle).font(.subheadline).foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    ToolbarItem(placement: .status) {
                        ConnectionState(state: model.state, lastUpdate: client.lastUpdate)
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            client.refresh()
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        .help("Refresh (⌘R)")
                    }
                }
        }
    }
}

/// The sidebar: views by section, and Symphony's version and state at the foot.
struct SymphonySidebar: View {
    @ObservedObject var model: SymphonyWindowModel

    var body: some View {
        List(selection: selection) {
            ForEach(model.sidebar.sections, id: \.section) { group in
                Section {
                    ForEach(group.views, id: \.self) { view in
                        Label(view.title, systemImage: view.symbol)
                            .help(shortcutHelp(view))
                            .tag(view)
                    }
                } header: {
                    if let title = group.section.title { Text(title) }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: DesignTokens.Space.s2) {
                        Circle()
                            .fill(model.state.connectionStatus.tint)
                            .frame(width: 8, height: 8)
                            .accessibilityHidden(true)
                        Text(model.footerState)
                            .font(DesignTokens.TypeStyle.callout.font)
                    }
                    Text(model.footerVersion)
                        .font(DesignTokens.TypeStyle.caption.font)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 8 + DesignTokens.Space.s2)
                }
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DesignTokens.Space.s4)
            .padding(.vertical, DesignTokens.Space.s2)
        }
    }

    /// The list's selection, which opens the Repos window instead of selecting it.
    private var selection: Binding<SymphonyView?> {
        Binding(
            get: { model.selection },
            set: { view in
                guard let view else { return }
                model.show(view)
            }
        )
    }

    private func shortcutHelp(_ view: SymphonyView) -> String {
        model.sidebar.shortcut(for: view).map { "\(view.title) (⌘\($0))" } ?? view.title
    }
}

/// The selected view, or the one placeholder every view shows while Symphony can't serve it (D0).
struct SymphonyDetail: View {
    @ObservedObject var model: SymphonyWindowModel
    @ObservedObject var client: LiveAPIClient

    var body: some View {
        if let placeholder = model.state.placeholder {
            EmptyState(
                title: placeholder.title,
                symbol: placeholder.symbol,
                actions: placeholder.actions.map { action in (action.title, { model.onAction(action) }) },
                showsSpinner: placeholder.showsSpinner
            )
        } else {
            switch model.selection {
            case .diagnostics:
                DiagnosticsContent(model: model, client: client)
            default:
                EmptyState(title: EndpointPlaceholder.updateSymphony, symbol: EndpointPlaceholder.updateSymbol)
            }
        }
    }
}

/// D11: Symphony's own health, from `/api/v1/state`.
struct DiagnosticsContent: View {
    @ObservedObject var model: SymphonyWindowModel
    @ObservedObject var client: LiveAPIClient

    var body: some View {
        if let payload = client.diagnostics {
            DiagnosticsView(
                report: DiagnosticsReport(payload: payload, apiURL: model.apiURL(), lastUpdate: client.lastUpdate),
                actions: DiagnosticsView.Actions(
                    copyStateJSON: model.copyStateJSON,
                    openLogs: model.canOpenLogs() ? { model.onAction(.openLogs) } : nil,
                    openWebDashboard: model.canOpenWebDashboard() ? model.onOpenWebDashboard : nil
                )
            )
        } else if client.stateResult == .unsupported {
            EmptyState(title: EndpointPlaceholder.updateSymphony, symbol: EndpointPlaceholder.updateSymbol)
        } else {
            EmptyState(title: "Reading Symphony's state…", symbol: "stethoscope", showsSpinner: true)
        }
    }
}

/// Diagnostics' groups as cards of label and value rows, under its actions.
struct DiagnosticsView: View {
    struct Actions {
        var copyStateJSON: () -> Void
        /// Nil while the action can't be taken, which disables its button.
        var openLogs: (() -> Void)?
        var openWebDashboard: (() -> Void)?
    }

    let report: DiagnosticsReport
    let actions: Actions

    var body: some View {
        ScrollView {
            DiagnosticsCards(report: report, actions: actions)
        }
    }
}

/// Diagnostics' actions and cards, outside the scroll view so they also render offscreen.
struct DiagnosticsCards: View {
    let report: DiagnosticsReport
    let actions: DiagnosticsView.Actions

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s4) {
            HStack(spacing: DesignTokens.Space.s2) {
                Spacer()
                Button("Copy State JSON", action: actions.copyStateJSON)
                Button(StatusMenu.openLogsTitle) { actions.openLogs?() }
                    .disabled(actions.openLogs == nil)
                Button(StatusMenu.openWebDashboardTitle) { actions.openWebDashboard?() }
                    .disabled(actions.openWebDashboard == nil)
            }
            ForEach(report.groups, id: \.title) { group in
                Card(title: group.title) {
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: DesignTokens.Space.s4,
                         verticalSpacing: DesignTokens.Space.s2) {
                        ForEach(Array(group.rows.enumerated()), id: \.offset) { _, row in
                            DiagnosticsRow(row: row)
                        }
                    }
                }
            }
        }
        .padding(DesignTokens.Space.s5)
    }
}

private struct DiagnosticsRow: View {
    let row: DiagnosticsReport.Row

    var body: some View {
        GridRow {
            Text(row.label)
                .font(row.monospacedLabel ? DesignTokens.TypeStyle.mono.font : DesignTokens.TypeStyle.body.font)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.leading)
                .frame(minWidth: 140, alignment: .leading)
            VStack(alignment: .leading, spacing: DesignTokens.Space.s1 / 2) {
                HStack(spacing: DesignTokens.Space.s2) {
                    if let status = row.status {
                        Image(systemName: status.symbol)
                            .foregroundStyle(status.tint)
                            .accessibilityLabel(status.word)
                    }
                    Text(row.value)
                        .font(row.monospacedValue ? DesignTokens.TypeStyle.mono.font : DesignTokens.TypeStyle.body.font)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .textSelection(.enabled)
                }
                if let detail = row.detail {
                    Text(detail)
                        .font(DesignTokens.TypeStyle.mono.font)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}
