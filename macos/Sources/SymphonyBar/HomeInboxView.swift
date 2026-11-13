import SwiftUI
import SymphonyBarCore
import SymphonyBarUI

// TP-1454: Home's top (the Inbox's items, answerable in place), the Inbox's drawer, and the window's status bar.

/// What Home's Inbox rows do: the same picks, write-ins and moves as the Inbox, through the window model.
struct HomeInboxActions {
    /// Picks an option: (option, decision, issue id).
    var pick: (Int, Int, String) -> Void = { _, _, _ in }
    /// Keeps a write-in's text: (text, decision, issue id).
    var writeIn: (String, Int, String) -> Void = { _, _, _ in }
    /// A move opens its consequence sheet; a link opens.
    var perform: (InboxCommand, InboxItem) -> Void = { _, _ in }
    /// Review: the drawer on the item, by issue id.
    var review: (String) -> Void = { _ in }
    var openTicket: (String) -> Void = { _ in }
    var openMention: (Mention) -> Void = { _ in }
    var openMentionDirectly: (Mention) -> Void = { _ in }
}

extension SymphonyWindowModel {
    var homeInboxActions: HomeInboxActions {
        HomeInboxActions(
            pick: { [weak self] in self?.pick($0, decision: $1, itemID: $2) },
            writeIn: { [weak self] in self?.writeIn($0, decision: $1, itemID: $2) },
            perform: { [weak self] in self?.perform($0, on: $1) },
            review: { [weak self] in self?.reviewInDrawer($0) },
            openTicket: { [weak self] in self?.openTicket($0) },
            // A chip in a row opens its peek in the drawer, beside Home.
            openMention: { [weak self] mention in
                guard let self else { return }
                inboxDrawerShown = true
                openPeek(mention)
            },
            openMentionDirectly: { [weak self] in self?.openMentionDirectly($0) }
        )
    }
}

// MARK: - Home's top

/// Every Inbox item above the board, newest first: a Question with its option cards, answered in place; a pause or a
/// hold with its moves; each with Review, which opens the drawer. An answered item leaves with the standard motion.
struct HomeInboxSection: View {
    let inbox: HomeInbox
    let actions: HomeInboxActions
    var now = Date()
    /// True in a narrow window: an option card's badge goes under its label.
    var narrow = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s3) {
            HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.s2) {
                Image(systemName: DesignTokens.SituationKind.you.symbol)
                    .foregroundStyle(DesignTokens.SituationKind.you.tint)
                    .accessibilityHidden(true)
                Text(HomeInbox.title)
                    .font(DesignTokens.TypeStyle.heading.font)
                Text(inbox.rows.count, format: .number)
                    .font(DesignTokens.TypeStyle.secondary.font)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer(minLength: DesignTokens.Space.s2)
                if let hiddenLine = inbox.hiddenLine {
                    Text(hiddenLine)
                        .font(DesignTokens.TypeStyle.secondary.font)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(inbox.accessibilityLabel)
            .accessibilityAddTraits(.isHeader)
            ForEach(inbox.rows) { row in
                HomeInboxRow(row: row, actions: actions, now: now, narrow: narrow)
                    .transition(.asymmetric(
                        insertion: .opacity,
                        removal: reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .leading))
                    ))
            }
        }
        .animation(reduceMotion ? nil : .standard, value: inbox.rows.map(\.id))
    }
}

/// One Inbox item on Home: its kind, age and ticket, then the Question block for a request with options, or its ask;
/// under them the Inbox's buttons for the item, its ⋯ menu and Review.
struct HomeInboxRow: View {
    let row: HomeInbox.Row
    let actions: HomeInboxActions
    var now = Date()
    var narrow = false
    @Environment(\.offscreenSnapshot) private var offscreenSnapshot

    private var item: InboxItem { row.item }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous) }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s3) {
            header
            if row.asksInPlace, let action = item.review.action {
                QuestionBlock(
                    action: action,
                    // The row's own picks, so a pick changes the row and redraws its cards.
                    picks: row.picks,
                    pick: { actions.pick($0, 0, item.id) },
                    writeIn: { actions.writeIn($0, 0, item.id) },
                    answerable: item.answerable,
                    narrow: narrow,
                    showsKeys: false
                )
            } else {
                ChipText(text: item.ask)
            }
            buttons
        }
        .padding(PanelStyle.padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelSurface(in: shape)
        .environment(\.mentionReferences, item.references)
        .environment(\.openMention, OpenMentionAction(handler: actions.openMention))
        .environment(\.openMentionDirectly, OpenMentionAction(handler: actions.openMentionDirectly))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(item.accessibilityLabel)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.s2) {
            StatusBadge(status: item.kind.status, word: item.kindWord).fixedSize()
            Button { actions.openTicket(item.identifier) } label: {
                HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.s2) {
                    Text(item.identifier).font(DesignTokens.TypeStyle.rowTitle.font)
                    if let title = item.title {
                        Text(title).font(DesignTokens.TypeStyle.body.font).lineLimit(1)
                    }
                }
                .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
            // A Question on Symphony itself (a report's) has no ticket page to open.
            .disabled(item.isSubject)
            .help(item.isSubject ? "" : "Open \(item.identifier)")
            .accessibilityHint(item.isSubject ? "" : "Opens the ticket page")
            if let repo = item.repoKey {
                Text(repo)
                    .font(DesignTokens.TypeStyle.secondary.font)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: DesignTokens.Space.s2)
            if let age = item.age {
                Label("Waiting \(age)", systemImage: "clock")
                    .font(DesignTokens.TypeStyle.secondary.font)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
            }
        }
    }

    /// The Inbox's buttons for the item, the first prominent, its ⋯ menu, and Review at the trailing edge.
    private var buttons: some View {
        HStack(spacing: DesignTokens.Space.s2) {
            ForEach(Array(row.toolbar.buttons.enumerated()), id: \.offset) { index, button in
                Button(button.command.title) { actions.perform(button.command, item) }
                    .directorButton(index == 0 ? .primary : .secondary, size: .medium)
                    .disabled(!button.enabled)
            }
            if !row.toolbar.overflow.isEmpty {
                if offscreenSnapshot {
                    Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
                } else {
                    Menu {
                        ForEach(Array(row.toolbar.overflow.enumerated()), id: \.offset) { _, command in
                            Button(command.title) { actions.perform(command, item) }
                        }
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("More actions")
                }
            }
            Spacer(minLength: DesignTokens.Space.s2)
            Button(HomeInbox.reviewTitle) { actions.review(item.id) }
                .directorButton(.quiet, size: .medium)
                .help("Open the whole review in the Inbox drawer")
        }
    }
}

// MARK: - The drawer

/// The Inbox's drawer: the window's inspector on Home and on a ticket page, holding the review of the item selected,
/// or a peek (N4) opened from its chips, whose Close returns to the review.
struct InboxDrawerPresenter: ViewModifier {
    @ObservedObject var model: SymphonyWindowModel

    func body(content: Content) -> some View {
        content.inspector(isPresented: $model.inboxDrawerShown) {
            InboxDrawer(model: model)
                .inspectorColumnWidth(
                    min: PeekPresentation.minInspectorWidth,
                    ideal: HomeInbox.drawerIdealWidth,
                    max: HomeInbox.drawerMaxWidth
                )
        }
    }
}

/// The drawer's content: the peek while one is open, else the review of the selected item, with Close.
struct InboxDrawer: View {
    @ObservedObject var model: SymphonyWindowModel

    var body: some View {
        if model.peek.isShown {
            PeekView(model: model)
        } else if let list = model.inboxList, let item = list.selection(model.inboxSelection) {
            VStack(spacing: 0) {
                InboxDrawerHeader(title: HomeInbox.drawerTitle, close: { model.inboxDrawerShown = false })
                Divider()
                ScrollView {
                    InboxReviewBody(
                        item: item,
                        picks: model.picks(for: item.id),
                        pick: { model.pick($0, decision: $1, itemID: item.id) },
                        writeIn: { model.writeIn($0, decision: $1, itemID: item.id) },
                        perform: { model.perform($0, on: item) },
                        // A Question on Symphony itself opens no ticket page.
                        openTicket: { if !item.isSubject { model.openTicket(item.identifier) } },
                        openMention: model.openPeek,
                        openMentionDirectly: model.openMentionDirectly,
                        narrow: true,
                        now: model.overviewState?.generatedAt ?? Date(),
                        evidence: WatcherEvidence(item: item, watch: model.watchState.watches[item.identifier]),
                        state: model.overviewState?.snapshot
                    )
                }
                .modifier(RememberedScroll(offset: model.inboxScroll[item.id], remember: { model.inboxScroll[item.id] = $0 }))
                // A new item starts at its own top, with its own picks.
                .id(item.id)
                .questionKeys({ item.optionIndex(forKey: $0) }) { model.pick($0, decision: 0, itemID: item.id) }
            }
        } else {
            VStack(spacing: 0) {
                InboxDrawerHeader(title: HomeInbox.drawerTitle, close: { model.inboxDrawerShown = false })
                Divider()
                if model.inboxList != nil {
                    InboxEmpty(hiddenLine: model.inboxList?.hiddenLine)
                } else {
                    EmptyState(title: "Reading the Inbox…", symbol: SymphonyView.inbox.symbol, showsSpinner: true)
                }
            }
        }
    }
}

/// The drawer's title and its Close (Esc).
struct InboxDrawerHeader: View {
    let title: String
    let close: () -> Void

    var body: some View {
        HStack(spacing: DesignTokens.Space.s2) {
            Text(title)
                .font(DesignTokens.TypeStyle.heading.font)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: DesignTokens.Space.s2)
            Button(action: close) { Label(PeekNavigation.closeTitle, systemImage: "xmark") }
                .labelStyle(.iconOnly)
                .directorButton(.quiet, size: .small)
                .keyboardShortcut(.cancelAction)
                .help("Close (Esc)")
        }
        .padding(.horizontal, DesignTokens.Space.s4)
        .padding(.vertical, DesignTokens.Space.s2)
    }
}

/// C17: the Inbox's consequence sheets, from Home's rows, the drawer and the ticket page's Question.
struct InboxSheetPresenter: ViewModifier {
    @ObservedObject var model: SymphonyWindowModel

    func body(content: Content) -> some View {
        content.sheet(item: $model.inboxSheet) { sheet in
            ConsequenceSheetView(
                sheet: sheet,
                working: model.inboxMoveInFlight,
                error: model.inboxMoveError,
                cancel: model.cancelSheet,
                confirm: { reason in model.confirm(sheet, reason: reason) }
            )
        }
    }
}

// MARK: - The status bar

/// The window's status bar: the dispatch control, then the factory's health in one line.
struct WindowStatusBar: View {
    @ObservedObject var model: SymphonyWindowModel
    @ObservedObject var client: LiveAPIClient
    /// When the last state arrived, for the health line's help: the status bar alone draws again each poll (TP-1480).
    @ObservedObject var heartbeat: StateHeartbeat

    init(model: SymphonyWindowModel, client: LiveAPIClient) {
        self.model = model
        self.client = client
        heartbeat = client.heartbeat
    }

    var body: some View {
        StatusBarContent(line: model.healthLine) {
            DispatchControlButton(model: model, client: client)
        }
    }
}

/// The status bar's layout, with the control it is given: outside the window, so it also renders offscreen.
struct StatusBarContent<Control: View>: View {
    let line: HealthLine
    @ViewBuilder let control: Control

    static var height: CGFloat { 32 }

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: DesignTokens.Space.s3) {
                control
                ForEach(Array(line.parts.enumerated()), id: \.offset) { _, part in
                    HStack(spacing: DesignTokens.Space.s1) {
                        if let status = part.status {
                            Circle()
                                .fill(status.tint)
                                .frame(width: 7, height: 7)
                                .accessibilityHidden(true)
                        }
                        Text(part.text)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .help(part.help ?? part.text)
                }
                Spacer(minLength: 0)
            }
            .font(DesignTokens.TypeStyle.secondary.font)
            .foregroundStyle(.secondary)
            .padding(.horizontal, DesignTokens.Space.s3)
            .frame(height: Self.height)
        }
        .background(DesignTokens.Surface.window.color)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(line.accessibilityLabel)
    }
}
