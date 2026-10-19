import AppKit
import SwiftUI
import SymphonyBarCore

// MARK: - The window model's Setup

extension SymphonyWindowModel {
    /// What Setup shows: the state poll's payload, or a fix's or Check Again's answer while it is newer. Nil from a
    /// Symphony that predates Setup.
    var setupPayload: SetupPayload? {
        guard let state = overviewState?.snapshot.setup else { return nil }
        return SetupPayload.newest(state, setupAnswer)
    }

    /// The state the Overview reads, with Setup's newest payload, so its Setup row follows a fix at once.
    var overviewWithSetup: OverviewState? {
        guard var state = overviewState else { return nil }
        state.snapshot.setup = setupPayload
        return state
    }

    /// J11: the app's warning when Symphony runs another build.
    var setupBuildWarning: SetupPayload.Problem? {
        SetupBuildCheck.warning(serviceVersion: overviewState?.snapshot.serviceVersion, app: appBuild)
    }

    /// SU1: the sidebar badge's counts; nothing while counts are unknown or Symphony predates Setup.
    var setupSummary: SetupSummary {
        guard state.countsKnown, let payload = setupPayload else { return SetupSummary() }
        return SetupSummary(payload: payload, buildWarning: setupBuildWarning)
    }

    func setupPage(now: Date = Date()) -> SetupPage {
        let payload = setupPayload
        return SetupPage(payload: payload, buildWarning: payload == nil ? nil : setupBuildWarning, order: setupOrder, now: now)
    }

    /// Setup's toolbar button is Check Again rather than Refresh.
    var showsSetupCheck: Bool { selection == .setup && shownTicket == nil && state.countsKnown }

    /// ⌘R and the toolbar's button: reads Symphony's state again, and on Setup runs its checks again.
    func refresh() {
        if showsSetupCheck, overviewState?.snapshot.setup != nil { checkSetupAgain() }
        client.refresh()
    }

    /// Keeps the rows shown in their places after a poll or an answer (P7).
    func holdSetupOrder() {
        let order = setupPage().order
        if order != setupOrder { setupOrder = order }
    }

    /// Check Again (SU3): Symphony runs its checks now; the results stay on screen until it answers.
    func checkSetupAgain() {
        guard !setupChecking else { return }
        setupChecking = true
        Task {
            switch await onSetupRequest(nil) {
            case let .checked(payload):
                accept(payload)
            case let .failed(message):
                showSetupBanner(.failed(message))
            }
            setupChecking = false
            client.refresh()
        }
    }

    private func accept(_ payload: SetupPayload) {
        setupAnswer = SetupPayload.newest(setupAnswer, payload)
        holdSetupOrder()
    }

    /// A row's button: a fix opens its sheet; an `open` fix goes where the operator fixes it. `ticket` is the one a
    /// Re-sync on a Details line names.
    func perform(_ action: SetupPage.Action, on row: SetupPage.Row, ticket: String? = nil) {
        switch action {
        case .fix(.configEdit(let path, let action, let value)):
            guard setupSheet?.isWorking != true else { return }
            setupSheet = configSheet(row.problem, path: path, action: action, value: value)
        case .fix:
            guard setupSheet?.isWorking != true else { return }
            setupSheet = SetupFixSheet(problem: row.problem, ticket: ticket)
        case let .open(destination):
            open(destination)
        }
    }

    /// The config sheet with the exact edit of the file as it is now, or why the edit can't be made.
    private func configSheet(_ problem: SetupPayload.Problem, path: String, action: SetupPayload.ConfigAction, value: SetupValue) -> SetupFixSheet? {
        let file = SymphonyConfigFile(settingsPath: configPath())
        let text = file?.text()
        let edited: Result<String, Error>? = text.map { text in
            Result { try SetupConfigEdit.apply(path: path, action: action, value: value, to: text) }
        }
        return SetupFixSheet(problem: problem, text: text, edited: edited, fileName: file?.fileName ?? "symphony.yml")
    }

    func open(_ destination: SetupDestination) {
        switch destination {
        case .settings:
            onAction(.openSettings)
        case .symphonyYML:
            if let file = SymphonyConfigFile(settingsPath: configPath()) {
                NSWorkspace.shared.open(URL(fileURLWithPath: file.path))
            } else {
                onAction(.openSettings)
            }
        case let .linear(url):
            onOpenURL(url ?? URL(string: "https://linear.app")!)
        case let .drainReport(url):
            if let url { onOpenURL(url) } else { show(.tickets) }
        case .repos:
            onOpenRepos(nil)
        case .update:
            onAction(.checkForUpdates)
        }
    }

    /// Cancel or Close: nothing is sent.
    func cancelSetupSheet() {
        guard setupSheet?.isWorking != true else { return }
        setupSheet = nil
    }

    /// The sheet's verb, or Try Again: makes the fix. On success the sheet closes, the problems are checked again and
    /// the banner shows; on failure the sheet stays with the reason (SU9).
    func confirm(_ sheet: SetupFixSheet) {
        guard !sheet.isWorking, sheet.canConfirm else { return }
        var working = sheet
        working.start()
        setupSheet = working
        Task {
            if case let .configEdit(path, action, value) = sheet.fix {
                await applyConfigFix(working, path: path, action: action, value: value)
            } else if let descriptor = sheet.fix.descriptor(tickets: sheet.tickets.isEmpty ? nil : sheet.tickets) {
                switch await onSetupRequest(descriptor) {
                case let .checked(payload):
                    setupSheet = nil
                    accept(payload)
                    showSetupBanner(.fixed(working))
                case let .failed(message):
                    fail(working, message)
                }
            }
            client.refresh()
        }
    }

    /// SU7: the copy to `.bak` first, then the edit through the settings writer once `symphony check` passes, then
    /// Check Again.
    private func applyConfigFix(_ sheet: SetupFixSheet, path: String, action: SetupPayload.ConfigAction, value: SetupValue) async {
        guard let file = SymphonyConfigFile(settingsPath: configPath()) else {
            fail(sheet, "Settings names no symphony.yml, so nothing was saved.")
            return
        }
        let check = onCheckConfig
        do {
            let result = try await file.applySetupFix({ try SetupConfigEdit.apply(path: path, action: action, value: value, to: $0) }, at: Date()) { copy in
                await check(copy)
            }
            switch result {
            case let .applied(backup):
                setupSheet = nil
                showSetupBanner(.fixed(sheet, backup: backup))
                checkSetupAgain()
            case .unchanged:
                setupSheet = nil
                checkSetupAgain()
            case let .rejected(message):
                fail(sheet, "symphony check refused the change, so nothing was saved: \(ConfigCheck.reasonFirst(message))")
            }
        } catch {
            fail(sheet, "Couldn't change symphony.yml, so nothing was saved: \(error.localizedDescription)")
        }
    }

    private func fail(_ sheet: SetupFixSheet, _ message: String) {
        guard setupSheet?.id == sheet.id else { return }
        var failed = sheet
        failed.fail(message)
        setupSheet = failed
    }

    /// SU10: Undo writes the backup back byte for byte, then Symphony checks again.
    func undo(_ banner: SetupBanner) {
        guard let backup = banner.backup else { return }
        dismissSetupBanner()
        do {
            try backup.restore()
            showSetupBanner(.undone)
            checkSetupAgain()
        } catch {
            showSetupBanner(.failed("Couldn't put symphony.yml back: \(error.localizedDescription). The copy is \(backup.url.path)."))
        }
    }

    func dismissSetupBanner() {
        setupBannerTask?.cancel()
        setupBanner = nil
    }

    private func showSetupBanner(_ banner: SetupBanner) {
        setupBannerTask?.cancel()
        setupBanner = banner
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [.announcement: banner.text, .priority: NSAccessibilityPriorityLevel.high.rawValue]
        )
        setupBannerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(SetupBanner.duration))
            guard !Task.isCancelled, let self, setupBanner?.id == banner.id else { return }
            setupBanner = nil
        }
    }
}

// MARK: - The page

/// SU3–SU6: the Setup page, from `/api/v1/state`'s `setup` and the answers of its fixes.
struct SetupContent: View {
    @ObservedObject var model: SymphonyWindowModel

    var body: some View {
        if model.overviewState == nil {
            EmptyState(title: "Reading Symphony's setup…", symbol: SymphonyView.setup.symbol, showsSpinner: true)
        } else {
            let page = model.setupPage()
            switch page.mood {
            case .olderService:
                EmptyState(
                    title: page.sentence,
                    symbol: EndpointPlaceholder.updateSymbol,
                    actions: [(UpdateMenu.checkTitle, { model.onAction(.checkForUpdates) })]
                )
            case .checking:
                EmptyState(title: page.sentence, symbol: SymphonyView.setup.symbol, showsSpinner: true)
            case .healthy, .problems:
                ScrollView {
                    SetupPageBody(page: page, actions: actions)
                }
                .overlay(alignment: .bottom) {
                    if let banner = model.setupBanner {
                        SetupBannerView(banner: banner, undo: { model.undo(banner) }, close: model.dismissSetupBanner)
                            .padding(DesignTokens.Space.s4)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.standard, value: model.setupBanner)
                .sheet(item: sheet) { sheet in
                    SetupFixSheetView(sheet: sheet, cancel: model.cancelSetupSheet, confirm: { model.confirm(sheet) })
                }
            }
        }
    }

    private var actions: SetupPageActions {
        SetupPageActions(
            perform: { action, row, ticket in model.perform(action, on: row, ticket: ticket) },
            openTicket: model.openTicket
        )
    }

    private var sheet: Binding<SetupFixSheet?> {
        Binding(get: { model.setupSheet }, set: { if $0 == nil { model.cancelSetupSheet() } })
    }
}

struct SetupPageActions {
    var perform: (SetupPage.Action, SetupPage.Row, String?) -> Void = { _, _, _ in }
    var openTicket: (String) -> Void = { _ in }
}

/// The page's sentence, banners and cards, outside the scroll view so it also renders offscreen.
struct SetupPageBody: View {
    let page: SetupPage
    var actions = SetupPageActions()
    /// Rows whose Details start open (SU4's snapshot).
    var expanded: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s4) {
            SetupSentence(page: page)
            if let stale = page.staleBanner {
                Label {
                    Text(stale).font(DesignTokens.TypeStyle.body.font).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(DesignTokens.Status.you.tint)
                }
                .padding(DesignTokens.Space.s3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DesignTokens.Surface.raised.color, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.row, style: .continuous))
                .accessibilityElement(children: .combine)
            }
            if !page.errors.isEmpty {
                SetupCard(title: SetupPage.errorsTitle, severity: .error, groups: page.errors, actions: actions, expanded: expanded)
            }
            if !page.warnings.isEmpty {
                SetupCard(title: SetupPage.warningsTitle, severity: .warning, groups: page.warnings, actions: actions, expanded: expanded)
            }
            if !page.notChecked.isEmpty {
                Card(title: SetupPage.notCheckedTitle) {
                    VStack(alignment: .leading, spacing: DesignTokens.Space.s3) {
                        ForEach(page.notChecked) { check in
                            HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.s3) {
                                Image(systemName: "questionmark.circle")
                                    .foregroundStyle(DesignTokens.Status.idle.tint)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: DesignTokens.Space.s1 / 2) {
                                    Text(check.title).font(DesignTokens.TypeStyle.rowTitle.font)
                                    Text(check.reason)
                                        .font(DesignTokens.TypeStyle.callout.font)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
        }
        .padding(DesignTokens.Space.s5)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// P1: what is true now, then when it was checked.
private struct SetupSentence: View {
    let page: SetupPage

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.s3) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .font(DesignTokens.TypeStyle.sentence.font)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DesignTokens.Space.s1) {
                Text(page.sentence)
                    .font(DesignTokens.TypeStyle.sentence.font)
                    .accessibilityAddTraits(.isHeader)
                if let context = page.context {
                    Text(context)
                        .font(DesignTokens.TypeStyle.callout.font)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        if !page.errors.isEmpty { return SetupSeverityMark.error.symbol }
        if !page.warnings.isEmpty { return SetupSeverityMark.warning.symbol }
        return DesignTokens.Status.done.symbol
    }

    private var tint: Color {
        if !page.errors.isEmpty { return SetupSeverityMark.error.tint }
        if !page.warnings.isEmpty { return SetupSeverityMark.warning.tint }
        return DesignTokens.Status.done.tint
    }
}

/// An error's red filled triangle (`status.problem`), or a warning's orange outlined one: a warning asks nothing of
/// the operator, so it doesn't borrow `status.you`'s person symbol.
enum SetupSeverityMark {
    case error, warning

    init(_ severity: SetupPayload.Severity) {
        self = severity == .error ? .error : .warning
    }

    var symbol: String { self == .error ? DesignTokens.Status.problem.symbol : "exclamationmark.triangle" }
    var tint: Color { self == .error ? DesignTokens.Status.problem.tint : DesignTokens.Status.you.tint }
    var word: String { self == .error ? "Error" : "Warning" }
}

/// The Errors or the Warnings card: its rows under a heading per category.
private struct SetupCard: View {
    let title: String
    let severity: SetupPayload.Severity
    let groups: [SetupPage.Group]
    let actions: SetupPageActions
    let expanded: Set<String>

    var body: some View {
        Card(title: title) {
            VStack(alignment: .leading, spacing: DesignTokens.Space.s3) {
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
                        Text(group.title.uppercased())
                            .font(DesignTokens.TypeStyle.label.font)
                            .foregroundStyle(.secondary)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(group.rows) { row in
                            SetupRowView(row: row, severity: severity, actions: actions, startsExpanded: expanded.contains(row.id))
                            if row.id != group.rows.last?.id { Divider() }
                        }
                    }
                }
            }
            .animation(.standard, value: groups)
        }
    }
}

/// One problem: its title, the consequence, the repos and tickets it touches, its button, and Details (SU4).
struct SetupRowView: View {
    let row: SetupPage.Row
    let severity: SetupPayload.Severity
    let actions: SetupPageActions
    @State private var expanded: Bool

    init(row: SetupPage.Row, severity: SetupPayload.Severity, actions: SetupPageActions, startsExpanded: Bool = false) {
        self.row = row
        self.severity = severity
        self.actions = actions
        _expanded = State(initialValue: startsExpanded)
    }

    var body: some View {
        HStack(alignment: .top, spacing: DesignTokens.Space.s3) {
            Image(systemName: SetupSeverityMark(severity).symbol)
                .foregroundStyle(SetupSeverityMark(severity).tint)
                .accessibilityLabel(SetupSeverityMark(severity).word)
            VStack(alignment: .leading, spacing: DesignTokens.Space.s1) {
                Text(row.title)
                    .font(DesignTokens.TypeStyle.rowTitle.font)
                    .fixedSize(horizontal: false, vertical: true)
                Text(row.consequence)
                    .font(DesignTokens.TypeStyle.body.font)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if row.reposLine != nil || !row.tickets.isEmpty {
                    HStack(spacing: DesignTokens.Space.s2) {
                        if let repos = row.reposLine {
                            Text(repos).font(DesignTokens.TypeStyle.callout.font).foregroundStyle(.secondary)
                        }
                        ForEach(row.tickets, id: \.identifier) { ticket in
                            ticketLink(ticket.identifier).font(DesignTokens.TypeStyle.callout.font)
                        }
                    }
                }
                if !row.details.isEmpty {
                    Button {
                        withAnimation(.standard) { expanded.toggle() }
                    } label: {
                        Label(SetupPage.detailsTitle, systemImage: expanded ? "chevron.down" : "chevron.right")
                            .font(DesignTokens.TypeStyle.callout.font)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(expanded ? "Hide details" : "Show details")
                    if expanded { details }
                }
            }
            Spacer(minLength: DesignTokens.Space.s2)
            if let title = row.actionTitle, let action = row.action {
                actionButton(title, action)
            }
        }
        .padding(.vertical, DesignTokens.Space.s1)
    }

    @ViewBuilder private var details: some View {
        if row.resyncsPerTicket, case let .fix(fix)? = row.action {
            // Drift: one line per ticket, each with its own Re-sync.
            VStack(alignment: .leading, spacing: DesignTokens.Space.s1) {
                ForEach(row.tickets, id: \.identifier) { ticket in
                    HStack(spacing: DesignTokens.Space.s2) {
                        ticketLink(ticket.identifier).font(DesignTokens.TypeStyle.callout.font)
                        Text(row.detail(for: ticket.identifier) ?? "")
                            .font(DesignTokens.TypeStyle.callout.font)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: DesignTokens.Space.s2)
                        Button("Re-sync…") { actions.perform(.fix(fix), row, ticket.identifier) }
                            .controlSize(.small)
                    }
                }
            }
            .padding(.leading, DesignTokens.Space.s4)
        } else {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: DesignTokens.Space.s3, verticalSpacing: DesignTokens.Space.s1) {
                ForEach(row.details, id: \.self) { detail in
                    GridRow {
                        Text(detail.label)
                            .font(DesignTokens.TypeStyle.callout.font)
                            .foregroundStyle(.secondary)
                        Text(detail.value)
                            .font(DesignTokens.TypeStyle.mono.font)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.leading, DesignTokens.Space.s4)
        }
    }

    @ViewBuilder private func actionButton(_ title: String, _ action: SetupPage.Action) -> some View {
        let button = Button(title) { actions.perform(action, row, nil) }.fixedSize()
        if case .fix = action {
            button.buttonStyle(.borderedProminent)
        } else {
            button.buttonStyle(.bordered)
        }
    }

    /// A ticket as a link to its page, drawn in SwiftUI so it also renders offscreen.
    private func ticketLink(_ identifier: String) -> some View {
        Button { actions.openTicket(identifier) } label: {
            Text(identifier).foregroundStyle(Color.accentColor)
        }
        .buttonStyle(.plain)
        .help("Open \(identifier)'s page")
        .accessibilityAddTraits(.isLink)
    }
}

// MARK: - The sheet

/// SU7–SU9 (C17): the fix's question, what happens, the exact change, what stays, how to undo it, and Cancel with
/// the verb. A spinner shows while it works; a failure shows inline with Try Again and Close.
struct SetupFixSheetView: View {
    let sheet: SetupFixSheet
    let cancel: () -> Void
    let confirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s4) {
            Text(sheet.title)
                .font(DesignTokens.TypeStyle.sentence.font)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(sheet.happens)
                .font(DesignTokens.TypeStyle.body.font)
                .fixedSize(horizontal: false, vertical: true)
            change
            Text(sheet.stays)
                .font(DesignTokens.TypeStyle.body.font)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Label(sheet.undo, systemImage: "arrow.uturn.backward")
                .font(DesignTokens.TypeStyle.callout.font)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error = sheet.error {
                Label(error, systemImage: DesignTokens.Status.problem.symbol)
                    .font(DesignTokens.TypeStyle.callout.font)
                    .foregroundStyle(DesignTokens.Status.problem.tint)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: DesignTokens.Space.s2) {
                if sheet.isWorking {
                    ProgressView().controlSize(.small).accessibilityLabel("Working")
                }
                Spacer(minLength: 0)
                Button(sheet.cancelTitle, role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                    .disabled(sheet.isWorking)
                Button(sheet.confirmTitle, action: confirm)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!sheet.canConfirm)
            }
        }
        .padding(DesignTokens.Space.s5)
        .frame(width: 520)
    }

    @ViewBuilder private var change: some View {
        switch sheet.kind {
        case let .config(diff?):
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(diff.lines.enumerated()), id: \.offset) { _, line in
                    Text(line.marked)
                        .font(DesignTokens.TypeStyle.mono.font)
                        .foregroundStyle(lineColor(line.kind))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, DesignTokens.Space.s2)
                        .background(lineBackground(line.kind))
                }
            }
            .padding(.vertical, DesignTokens.Space.s2)
            .background(DesignTokens.Surface.raised.color, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.row, style: .continuous))
            .textSelection(.enabled)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Lines removed: \(diff.removed.joined(separator: ", ")). Lines added: \(diff.added.joined(separator: ", ")).")
        case .config(nil):
            EmptyView()
        case let .linear(lines):
            VStack(alignment: .leading, spacing: DesignTokens.Space.s1) {
                ForEach(lines, id: \.self) { line in
                    Text(line).font(DesignTokens.TypeStyle.body.font).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(DesignTokens.Space.s3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DesignTokens.Surface.raised.color, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.row, style: .continuous))
            .overlay(alignment: .leading) { Color.accentColor.frame(width: 3) }
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.row, style: .continuous))
            .accessibilityElement(children: .combine)
        }
    }

    private func lineColor(_ kind: SetupDiff.Line.Kind) -> AnyShapeStyle {
        switch kind {
        case .removed: AnyShapeStyle(DesignTokens.Status.problem.tint)
        case .added: AnyShapeStyle(DesignTokens.Status.done.tint)
        case .context, .gap: AnyShapeStyle(.secondary)
        }
    }

    private func lineBackground(_ kind: SetupDiff.Line.Kind) -> Color {
        switch kind {
        case .removed: DesignTokens.Status.problem.tint.opacity(0.10)
        case .added: DesignTokens.Status.done.tint.opacity(0.10)
        case .context, .gap: .clear
        }
    }
}

/// C18 at the foot of the Setup page: what a fix did, with Undo for 10 s after a settings fix (SU10).
struct SetupBannerView: View {
    let banner: SetupBanner
    let undo: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: DesignTokens.Space.s3) {
            Image(systemName: symbol).foregroundStyle(tint).accessibilityHidden(true)
            Text(banner.text)
                .font(DesignTokens.TypeStyle.body.font)
                .lineLimit(2)
            Spacer(minLength: DesignTokens.Space.s2)
            if banner.offersUndo {
                Button("Undo", action: undo)
            }
            Button(action: close) {
                Image(systemName: "xmark").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, DesignTokens.Space.s4)
        .padding(.vertical, DesignTokens.Space.s3)
        .background(DesignTokens.Surface.raised.color, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous)
                .strokeBorder(DesignTokens.Surface.separator.color)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(banner.text)
    }

    private var symbol: String {
        switch banner.style {
        case .success: DesignTokens.Status.done.symbol
        case .info: "arrow.uturn.backward.circle"
        case .error: DesignTokens.Status.problem.symbol
        }
    }

    private var tint: Color {
        switch banner.style {
        case .success: DesignTokens.Status.done.tint
        case .info: .secondary
        case .error: DesignTokens.Status.problem.tint
        }
    }
}
