import AppKit
import SwiftUI
import SymphonyBarCore

/// The Repos window: a sidebar of repos and the detail of the selected one, as `ReposList` describes them.
struct ReposView: View {
    static let defaultWidth: CGFloat = 880
    static let defaultHeight: CGFloat = 600
    static let minWidth: CGFloat = 720
    static let minHeight: CGFloat = 460

    @ObservedObject var model: ReposViewModel
    @FocusState private var sidebarFocused: Bool

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 300)
        } detail: {
            VStack(spacing: 0) {
                if let banner = model.shownBanner {
                    ReposBannerView(banner: banner) { model.banner = nil }
                }
                detail
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(minWidth: Self.minWidth, minHeight: Self.minHeight)
        .sheet(isPresented: Binding(get: { model.addRepo != nil }, set: { if !$0 { model.addRepo = nil } })) {
            if let addRepo = model.addRepo {
                AddRepoView(model: addRepo) { model.addRepo = nil }
            }
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $model.selection) {
            ForEach(model.window.repos) { repo in
                RepoSidebarRow(repo: repo)
                    .tag(repo.key)
                    .contextMenu { contextMenu(repo) }
            }
        }
        .listStyle(.sidebar)
        .focused($sidebarFocused)
        .onAppear { sidebarFocused = true }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                HStack(spacing: 2) {
                    Button { model.onAddRepo() } label: {
                        Image(systemName: "plus").frame(width: 22, height: 18)
                    }
                    .keyboardShortcut("n", modifiers: .command)
                    .help(AddRepo.buttonTitle)
                    .accessibilityLabel(AddRepo.buttonTitle)
                    Button { model.selection.map(model.onDisconnect) } label: {
                        Image(systemName: "minus").frame(width: 22, height: 18)
                    }
                    .keyboardShortcut(.delete, modifiers: [])
                    .disabled(model.selected == nil || model.selected?.actions.disconnectProblem != nil)
                    .help(model.selected?.actions.disconnectProblem ?? DisconnectRepo.buttonTitle)
                    .accessibilityLabel(DisconnectRepo.buttonTitle)
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
            }
            .background(.bar)
        }
    }

    @ViewBuilder private func contextMenu(_ repo: RepoDetail) -> some View {
        Button(EditRepo.buttonTitle) { model.onEdit(repo.key) }
            .disabled(repo.actions.editProblem != nil)
        Button(ReposList.revealTitle) { repo.source.path.map(reveal) }
            .disabled(repo.source.path == nil)
        Button(ReposList.openOnGitHubTitle) {
            if let url = repo.gitHubURL { NSWorkspace.shared.open(url) }
        }
            .disabled(repo.gitHubURL == nil)
        Divider()
        Button(DisconnectRepo.buttonTitle) { model.onDisconnect(repo.key) }
            .disabled(repo.actions.disconnectProblem != nil)
    }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        switch model.window.content {
        case let .empty(state):
            ReposEmptyView(state: state, model: model)
        case .repos:
            if let repo = model.selected {
                RepoDetailView(repo: repo, model: model)
            } else {
                Text("Select a repo")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

/// Shows `path` selected in a Finder window.
@MainActor private func reveal(_ path: String) {
    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
}

/// What the last change did, at the top of the detail, with a close button. The text wraps to at most
/// `maxLines` lines and never sizes itself: a banner that fixes its own height makes the split view probe it at a
/// tiny width, grow thousands of points tall and draw the whole window off-screen.
struct ReposBannerView: View {
    let banner: ReposBanner
    let dismiss: () -> Void
    static let maxLines = 4

    var body: some View {
        let isError = banner.style == .error
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(isError ? Color.red : Color.green)
                .accessibilityLabel(isError ? "Error" : "Done")
            Text(banner.text)
                .lineLimit(Self.maxLines)
                .truncationMode(.tail)
                .textSelection(.enabled)
                .help(banner.text)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: dismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help(ReposBanner.dismissTitle)
            .accessibilityLabel(ReposBanner.dismissTitle)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill((isError ? Color.red : Color.accentColor).opacity(0.1))
        )
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }
}

/// The toolbar chip with Symphony's state, or the restart under way with a pop-over of what it waits on.
struct ReposChipView: View {
    @ObservedObject var model: ReposViewModel
    @State private var showsPopover = false

    var body: some View {
        if let restart = model.restartChip {
            Button { showsPopover.toggle() } label: {
                capsule(title: restart.title, dot: .orange)
            }
            .buttonStyle(.plain)
            .help(restart.line ?? restart.title)
            .popover(isPresented: $showsPopover, arrowEdge: .bottom) {
                ReposRestartPopover(chip: restart, model: model)
            }
        } else {
            capsule(title: model.window.chip.title, dot: model.window.chip.dot)
        }
    }

    private func capsule(title: String, dot: ReposChip.Dot) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color(dot))
                .frame(width: 8, height: 8)
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .overlay(Capsule().strokeBorder(Color(nsColor: .separatorColor)))
        .contentShape(Capsule())
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
    }

    private func color(_ dot: ReposChip.Dot) -> Color {
        switch dot {
        case .green: return .green
        case .orange: return .orange
        case .grey: return .gray
        case .red: return .red
        }
    }
}

/// The restart chip's pop-over: what the restart does now, the runs it waits on, and Restart Now and Cancel Restart
/// while it can take them.
struct ReposRestartPopover: View {
    let chip: ReposRestartChip
    @ObservedObject var model: ReposViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(chip.title)
                .font(.headline)
            if let line = chip.line {
                Text(line)
                    .foregroundStyle(.secondary)
            }
            if !chip.runs.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(chip.runs, id: \.self) { run in
                        Text(run)
                            .textSelection(.enabled)
                    }
                }
            }
            if chip.showsRestartNow || chip.showsCancel {
                HStack {
                    Spacer()
                    if chip.showsCancel {
                        Button(chip.cancelTitle) { model.onCancelRestart() }
                    }
                    if chip.showsRestartNow {
                        Button(chip.restartNowTitle) { model.onRestartNow() }
                            .disabled(!chip.restartNowEnabled)
                            .help(chip.restartNowEnabled ? chip.restartNowTitle : ReposRestartChip.restartNowHelp)
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 300, alignment: .leading)
    }
}

/// A sidebar row: key, `owner/repo` or the folder name, Default and the running agents.
struct RepoSidebarRow: View {
    let repo: RepoDetail

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(repo.key)
                    .lineLimit(1)
                if let subtitle = repo.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 4)
            if repo.isDefault {
                Badge(text: ReposList.defaultBadge)
                    .help(ReposList.defaultHelp)
            }
            if repo.agentCount > 0 {
                Badge(text: "\(repo.agentCount)", prominent: true)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(repo.accessibilityLabel)
    }
}

/// A small capsule, such as **Default** or an agent count.
struct Badge: View {
    let text: String
    var prominent = false

    var body: some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .foregroundStyle(prominent ? Color.white : Color.secondary)
            .background(Capsule().fill(prominent ? Color.accentColor : Color.secondary.opacity(0.18)))
    }
}

/// The selected repo: header, then Source, Linear routing, WORKFLOW.md, Activity and Acceptance gate, then
/// Disconnect….
struct RepoDetailView: View {
    let repo: RepoDetail
    @ObservedObject var model: ReposViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.top, 16)
            Form {
                source
                routing
                live
                if let gate = repo.gate {
                    Section("Acceptance gate") {
                        FieldRow(field: gate.mode)
                        LabeledContent("Record") {
                            Text(gate.record).multilineTextAlignment(.trailing)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            footer
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(repo.key)
                .font(.title2.weight(.semibold))
                .lineLimit(1)
                .textSelection(.enabled)
            if let github = repo.github, let url = repo.gitHubURL {
                Link(github, destination: url)
                    .help(ReposList.openOnGitHubTitle)
            }
            if repo.isDefault {
                Badge(text: ReposList.defaultBadge)
                    .help(ReposList.defaultHelp)
            }
            Spacer()
            Button(EditRepo.buttonTitle) { model.onEdit(repo.key) }
                .disabled(repo.actions.editProblem != nil)
                .help(repo.actions.editProblem ?? "Change where the code comes from, the base branch, the Linear route "
                    + "and the acceptance gate.")
        }
    }

    private var source: some View {
        Section("Source") {
            LabeledContent("Kind", value: repo.source.kindTitle)
            if let path = repo.source.path, let shown = repo.source.shownPath {
                LabeledContent(repo.source.pathLabel) {
                    HStack(spacing: 8) {
                        Text(shown)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .help(path)
                        Button(ReposList.revealTitle) { reveal(path) }
                            .controlSize(.small)
                    }
                }
            } else if repo.source.notCloned {
                LabeledContent("Clone", value: ReposList.notClonedLine)
            }
            LabeledContent("Base branch", value: repo.source.baseBranch)
            if let removal = repo.actions.cloneRemoval, !repo.source.notCloned {
                HStack(alignment: .firstTextBaseline) {
                    if case let .blocked(reason) = removal {
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button(ManagedClones.buttonTitle) { model.onRemoveClone(repo.key) }
                        .disabled(removal.path == nil)
                        .help(cloneRemovalHelp(removal))
                }
            }
        }
    }

    private var routing: some View {
        Section("Linear routing") {
            VStack(alignment: .leading, spacing: 2) {
                Text(repo.routing.sentence)
                if let line = repo.routing.defaultLine {
                    Text(line).foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            ForEach(repo.routing.fields, id: \.label) { FieldRow(field: $0) }
        }
    }

    @ViewBuilder private var live: some View {
        switch repo.live {
        case let .folded(line, canStart):
            Section("WORKFLOW.md and activity") {
                HStack(alignment: .firstTextBaseline) {
                    Text(line)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    if canStart {
                        Button(StatusMenu.startTitle) { model.onStart() }
                            .disabled(!model.canStart)
                    }
                }
            }
        case let .status(workflow, lastFetch, agents, agentsProblem):
            Section("WORKFLOW.md") {
                FieldRow(field: workflow)
            }
            Section("Activity") {
                FieldRow(field: lastFetch)
                if let agentsProblem {
                    Text(agentsProblem)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if agents.isEmpty {
                    Text(ReposList.noAgentsLine).foregroundStyle(.secondary)
                } else {
                    ForEach(agents, id: \.issueIdentifier) { agent in
                        HStack(alignment: .firstTextBaseline) {
                            Text(agent.title)
                            if let path = agent.worktreePath {
                                Text((path as NSString).abbreviatingWithTildeInPath)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .textSelection(.enabled)
                                    .help(path)
                            }
                            Spacer()
                            if let path = agent.worktreePath {
                                Button(ReposList.revealWorktreeTitle) { reveal(path) }
                                    .controlSize(.small)
                            }
                        }
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            // A bordered macOS button ignores the role and the label's colour; a red tint on a prominent one shows.
            Button(DisconnectRepo.buttonTitle, role: .destructive) { model.onDisconnect(repo.key) }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(repo.actions.disconnectProblem != nil)
                .help(repo.actions.disconnectProblem ?? "Remove the repo from symphony.yml. No folder is deleted.")
            if let problem = repo.actions.disconnectProblem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
        }
    }

    private func cloneRemovalHelp(_ removal: ManagedClones.Removal) -> String {
        switch removal {
        case let .allowed(path):
            return "Delete Symphony's clone at \((path as NSString).abbreviatingWithTildeInPath)."
        case let .blocked(reason):
            return reason
        }
    }
}

/// A label and its value, with the detail under the value in small selectable text.
struct FieldRow: View {
    let field: RepoField

    var body: some View {
        LabeledContent(field.label) {
            VStack(alignment: .trailing, spacing: 1) {
                Text(field.value)
                    .foregroundStyle(field.tone == .problem ? Color.red : Color.primary)
                if let detail = field.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                        .lineLimit(3)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
        }
        .help(field.detail ?? field.value)
    }
}

/// No repos, no `symphony.yml` set, or one that can't be read, each with its way out.
struct ReposEmptyView: View {
    let state: ReposEmptyState
    @ObservedObject var model: ReposViewModel

    var body: some View {
        // The geometry reader and scroll view keep the wrapped text from setting the split view's
        // minimum height: without them the column can grow taller than the window and push the
        // sidebar footer off screen.
        GeometryReader { proxy in
            ScrollView {
                content
                    .padding(40)
                    .frame(maxWidth: 480)
                    .frame(width: proxy.size.width)
                    .frame(minHeight: proxy.size.height)
            }
        }
    }

    private var content: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(state.title)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            Text(state.message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            switch state {
            case .noRepos:
                Button(AddRepo.buttonTitle) { model.onAddRepo() }
                    .keyboardShortcut(.defaultAction)
            case .noConfig:
                Button(ReposList.openSettingsTitle) { model.onOpenSettings() }
                    .keyboardShortcut(.defaultAction)
            case let .unreadable(path, message):
                Text(message)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.1)))
                HStack {
                    Button(ReposList.revealTitle) { reveal(path) }
                    Button(ReposList.tryAgainTitle) { model.onTryAgain() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private var icon: String {
        switch state {
        case .noRepos: return "square.stack.3d.up"
        case .noConfig: return "gearshape"
        case .unreadable: return "exclamationmark.triangle"
        }
    }
}
