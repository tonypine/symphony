import SwiftUI
import SymphonyBarCore

/// D2a–D2e: the Inbox, from `/api/v1/inbox`, under the window's scope.
struct InboxContent: View {
    @ObservedObject var model: SymphonyWindowModel
    @ObservedObject var client: LiveAPIClient

    var body: some View {
        if let list = model.inboxList {
            InboxView(
                list: list,
                selection: $model.inboxSelection,
                picks: model.picks(for:),
                pick: model.pick,
                writeIn: model.writeIn,
                perform: { model.perform($0, on: $1) },
                openOverview: { model.show(.overview) },
                openTicket: model.openTicket,
                openMention: model.openPeek,
                openMentionDirectly: model.openMentionDirectly
            )
            // N4: a chip opens its peek beside the review, or over the window when that would leave it too narrow.
            .modifier(PeekPresenter(model: model))
            .safeAreaInset(edge: .bottom) {
                if let banner = model.inboxBanner {
                    InboxBannerView(banner: banner, undo: { model.undo(banner) }, close: model.dismissBanner)
                        .padding(DesignTokens.Space.s3)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.default, value: model.inboxBanner)
            .sheet(item: $model.inboxSheet) { sheet in
                ConsequenceSheetView(
                    sheet: sheet,
                    working: model.inboxMoveInFlight,
                    error: model.inboxMoveError,
                    cancel: model.cancelSheet,
                    confirm: { reason in model.confirm(sheet, reason: reason) }
                )
            }
        } else if model.inboxResult == .unsupported {
            EmptyState(title: EndpointPlaceholder.updateSymphony, symbol: EndpointPlaceholder.updateSymbol)
        } else {
            EmptyState(title: "Reading the Inbox…", symbol: SymphonyView.inbox.symbol, showsSpinner: true)
        }
    }
}

/// P4: the list grouped by kind beside the review of the selected item, like Mail; D2e when nothing waits.
struct InboxView: View {
    let list: InboxList
    @Binding var selection: String?
    /// A plan's picks, by issue id.
    let picks: (String) -> DecisionPicks
    /// Picks an option: (option, decision, issue id).
    let pick: (Int, Int, String) -> Void
    /// Keeps the write-in's text: (text, issue id).
    var writeIn: (String, String) -> Void = { _, _ in }
    let perform: (InboxCommand, InboxItem) -> Void
    let openOverview: () -> Void
    /// A double-click on a row, or the review header's title, opens the ticket's page (D3).
    var openTicket: (String) -> Void = { _ in }
    /// A click on a chip in the review: its peek (N4).
    var openMention: (Mention) -> Void = { _ in }
    /// ⌘-click on a chip: the ticket's page, or the pull request on GitHub.
    var openMentionDirectly: (Mention) -> Void = { _ in }
    /// True while the review is narrower than `narrowReviewWidth`.
    @State private var narrow = false

    var body: some View {
        if list.isEmpty {
            InboxEmpty(hiddenLine: list.hiddenLine, openOverview: openOverview)
        } else {
            HStack(spacing: 0) {
                InboxListColumn(list: list, selection: $selection, picks: picks, perform: perform, openTicket: openTicket)
                    .frame(width: DesignTokens.Layout.listColumnWidth)
                    .background(DesignTokens.Surface.content.color)
                Divider()
                if let item = list.selection(selection) {
                    ScrollView {
                        ScrollViewReader { proxy in
                            InboxReviewBody(
                                item: item,
                                picks: picks(item.id),
                                pick: { option, decision in pick(option, decision, item.id) },
                                writeIn: { writeIn($0, item.id) },
                                perform: { perform($0, item) },
                                openTicket: { openTicket(item.identifier) },
                                openMention: openMention,
                                openMentionDirectly: openMentionDirectly,
                                narrow: narrow
                            )
                            // Picking the write-in scrolls its field into view, once it is laid out.
                            .onChange(of: item.review.action?.isWriteIn(picks(item.id)) == true) { _, picked in
                                guard picked else { return }
                                DispatchQueue.main.async { withAnimation { proxy.scrollTo(WriteInField.scrollID, anchor: .bottom) } }
                            }
                        }
                    }
                    // A new item starts with its own picks (the recommended options).
                    .id(item.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // A click in the review gives it the keyboard, so its number keys pick there too.
                    .focusable()
                    .focusEffectDisabled()
                    .onGeometryChange(for: Bool.self) { $0.size.width < DesignTokens.Layout.narrowReviewWidth } action: { narrow = $0 }
                }
            }
            // A number key picks the request's option with that number, while the list or the review has the keyboard;
            // in the write-in's field it types.
            .onKeyPress(characters: .decimalDigits, phases: .down) { press in
                guard press.modifiers.isEmpty, !(NSApp.keyWindow?.firstResponder is NSText),
                    let item = list.selection(selection), let key = press.characters.first,
                    let option = item.optionIndex(forKey: key)
                else { return .ignored }
                pick(option, 0, item.id)
                return .handled
            }
        }
    }
}

/// D2e: good news, and the way back to the Overview. A scope that hides items says so (P6).
struct InboxEmpty: View {
    let hiddenLine: String?
    let openOverview: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(InboxList.emptyTitle, systemImage: "tray")
        } description: {
            if let hiddenLine { Text(hiddenLine) }
        } actions: {
            Button(InboxList.openOverviewTitle, action: openOverview).buttonStyle(.borderedProminent)
        }
    }
}

/// The list column: ↑↓ move the selection, Return takes the review's default action (a move opens its sheet).
private struct InboxListColumn: View {
    let list: InboxList
    @Binding var selection: String?
    let picks: (String) -> DecisionPicks
    let perform: (InboxCommand, InboxItem) -> Void
    let openTicket: (String) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                InboxListRows(list: list, selected: list.selection(selection)?.id, select: { selection = $0 }, open: openTicket)
            }
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            .onAppear { focused = true }
            .onKeyPress(.downArrow) { move(by: 1, proxy: proxy) }
            .onKeyPress(.upArrow) { move(by: -1, proxy: proxy) }
            .onKeyPress(.return) {
                guard let item = list.selection(selection),
                    let command = InboxToolbar.toolbar(for: item, picks: picks(item.id)).defaultCommand
                else { return .ignored }
                // A move only opens its sheet.
                perform(command, item)
                return .handled
            }
        }
    }

    private func move(by offset: Int, proxy: ScrollViewProxy) -> KeyPress.Result {
        let items = list.ordered
        guard let current = list.selection(selection), let index = items.firstIndex(of: current) else { return .ignored }
        let next = items[max(0, min(items.count - 1, index + offset))]
        selection = next.id
        proxy.scrollTo(next.id)
        return .handled
    }
}

/// The groups and their rows, outside the scroll view so they also render offscreen.
struct InboxListRows: View {
    let list: InboxList
    let selected: String?
    let select: (String) -> Void
    /// Opens the ticket's page, by identifier.
    var open: (String) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s1) {
            ForEach(list.groups) { group in
                Text(group.title)
                    .font(DesignTokens.TypeStyle.label.font)
                    .foregroundStyle(.secondary)
                    .padding(.top, DesignTokens.Space.s3)
                    .padding(.horizontal, DesignTokens.Space.s3)
                    .accessibilityAddTraits(.isHeader)
                ForEach(group.items) { item in
                    InboxRow(item: item, selected: item.id == selected)
                        .id(item.id)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { open(item.identifier) }
                        .onTapGesture { select(item.id) }
                        .accessibilityAction { select(item.id) }
                        .accessibilityAction(named: "Open Ticket") { open(item.identifier) }
                }
            }
            if let hiddenLine = list.hiddenLine {
                Text(hiddenLine)
                    .font(DesignTokens.TypeStyle.callout.font)
                    .foregroundStyle(.secondary)
                    .padding(DesignTokens.Space.s3)
            }
        }
        .padding(DesignTokens.Space.s2)
    }
}

/// C8 in the Inbox: identifier and title, the ask, the age; one element for VoiceOver.
private struct InboxRow: View {
    let item: InboxItem
    let selected: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.s2) {
            Image(systemName: item.kind.symbol)
                .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(DesignTokens.Status.you.tint))
                .imageScale(.medium)
            VStack(alignment: .leading, spacing: DesignTokens.Space.s1 / 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(item.identifier).font(DesignTokens.TypeStyle.rowTitle.font)
                    Spacer(minLength: DesignTokens.Space.s2)
                    if let age = item.age {
                        Text(age)
                            .font(DesignTokens.TypeStyle.callout.font)
                            .monospacedDigit()
                            .foregroundStyle(selected ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
                    }
                }
                if let title = item.title {
                    Text(title).font(DesignTokens.TypeStyle.body.font).lineLimit(1)
                }
                Text(item.ask)
                    .font(DesignTokens.TypeStyle.callout.font)
                    .foregroundStyle(selected ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
                    .lineLimit(2)
            }
        }
        .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .padding(DesignTokens.Space.s3)
        .background(
            selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.clear),
            in: RoundedRectangle(cornerRadius: DesignTokens.Radius.row, style: .continuous)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.accessibilityLabel)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }
}

// MARK: - C15: the review

/// The review of one item: its header, its actions, and its sections by kind.
struct InboxReviewBody: View {
    let item: InboxItem
    var picks = DecisionPicks()
    var pick: (Int, Int) -> Void = { _, _ in }
    var writeIn: (String) -> Void = { _ in }
    let perform: (InboxCommand) -> Void
    var openTicket: () -> Void = {}
    /// A click on a ticket or pull request chip in the review's text, and a ⌘-click.
    var openMention: (Mention) -> Void = { _ in }
    var openMentionDirectly: (Mention) -> Void = { _ in }
    /// True in a narrow pane: an option card's Recommended badge goes under its label, the key hints hide, and the
    /// context card puts its labels above their values.
    var narrow = false
    /// The context card's clock: an earlier call today shows its time only.
    var now = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s4) {
            ReviewHeader(item: item, toolbar: InboxToolbar.toolbar(for: item, picks: picks), perform: perform, openTicket: openTicket)
            switch item.kind {
            case .plan:
                BriefSections(brief: item.review.brief, picks: picks, pick: pick, narrow: narrow)
                if !item.review.subTickets.isEmpty { SubTicketsCard(tickets: item.review.subTickets) }
            case .pr:
                if let pullRequest = item.review.pullRequest { ChecksCard(pullRequest: pullRequest) }
                BriefSections(brief: item.review.brief)
            case .action:
                if let action = item.review.action {
                    ActionCards(action: action, picks: picks, pick: { pick($0, 0) }, writeIn: writeIn, answerable: item.answerable, narrow: narrow)
                }
            case .clarify:
                if let clarify = item.review.clarify { ClarifyCards(clarify: clarify) }
            case .blocked:
                if let blocked = item.review.blocked { BlockedCards(blocked: blocked) }
            }
            if let context = ContextCard(item: item, now: now) {
                ContextCardView(card: context, narrow: narrow)
            }
        }
        .padding(DesignTokens.Space.s5)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The mentions in the review's text are chips (N1) with popovers (N2, N3).
        .environment(\.mentionReferences, item.references)
        .environment(\.openMention, OpenMentionAction(handler: openMention))
        .environment(\.openMentionDirectly, OpenMentionAction(handler: openMentionDirectly))
    }
}

private struct ReviewHeader: View {
    let item: InboxItem
    let toolbar: InboxToolbar
    let perform: (InboxCommand) -> Void
    let openTicket: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
            // The actions share the badges' row while it fits, and take a row of their own below them when it
            // doesn't, so a narrow pane never squeezes the badges or widens the window.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: DesignTokens.Space.s2) {
                    badges
                    Spacer(minLength: DesignTokens.Space.s2)
                    ActionButtons(toolbar: toolbar, perform: perform)
                }
                VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
                    HStack(spacing: DesignTokens.Space.s2) { badges }
                    ActionButtons(toolbar: toolbar, perform: perform)
                }
            }
            // The ticket's identifier and title open its page (D3, principle 5).
            Button(action: openTicket) {
                Text([item.identifier, item.title].compactMap { $0 }.joined(separator: " "))
                    .font(DesignTokens.TypeStyle.sentence.font)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
            }
            .buttonStyle(.plain)
            .help("Open the ticket page")
            .accessibilityAddTraits(.isHeader)
            .accessibilityHint("Opens the ticket page")
            // A decision's question, in the callout under the title, says what the ask would.
            if !item.isDecision {
                ChipText(text: item.ask, color: .secondaryLabelColor)
            }
        }
    }

    /// The kind pill, waiting time, state and repo, each kept on one line.
    @ViewBuilder private var badges: some View {
        StatusBadge(status: .you, word: item.kindWord)
            .fixedSize()
        if let age = item.age {
            Label("Waiting \(age)", systemImage: "clock")
                .font(DesignTokens.TypeStyle.label.font)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .fixedSize()
        }
        if let state = item.state {
            Text(state)
                .font(DesignTokens.TypeStyle.label.font)
                .padding(.horizontal, DesignTokens.Space.s2)
                .padding(.vertical, DesignTokens.Space.s1 / 2)
                .overlay(Capsule().strokeBorder(DesignTokens.Surface.separator.color))
                .fixedSize()
        }
        if let repo = item.repoKey {
            Text(repo)
                .font(DesignTokens.TypeStyle.label.font)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}

/// The review's actions (P4): the first is the prominent default (Open PR while a check is red, D2b), and the ⋯
/// menu holds the rest. A move only opens its sheet.
private struct ActionButtons: View {
    let toolbar: InboxToolbar
    let perform: (InboxCommand) -> Void
    @Environment(\.offscreenSnapshot) private var offscreenSnapshot

    var body: some View {
        HStack(spacing: DesignTokens.Space.s2) {
            ForEach(Array(toolbar.buttons.enumerated()), id: \.offset) { index, button in
                if index == 0 {
                    Button(button.command.title) { perform(button.command) }
                        .buttonStyle(.borderedProminent)
                        .disabled(!button.enabled)
                        // ⌘↩ sends a decision from anywhere in the Inbox.
                        .keyboardShortcut(button.command == .move(.decide) ? KeyboardShortcut(.return, modifiers: .command) : nil)
                } else {
                    Button(button.command.title) { perform(button.command) }
                        .disabled(!button.enabled)
                }
            }
            if !toolbar.overflow.isEmpty && offscreenSnapshot {
                Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
            } else if !toolbar.overflow.isEmpty {
                Menu {
                    ForEach(Array(toolbar.overflow.enumerated()), id: \.offset) { _, command in
                        Button(command.title) { perform(command) }
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
        .fixedSize()
    }
}

/// A brief in its parts, or as text when it didn't parse.
private struct BriefSections: View {
    let brief: InboxReview.Brief?
    var picks = DecisionPicks()
    var pick: (Int, Int) -> Void = { _, _ in }
    var narrow = false

    var body: some View {
        switch brief {
        case let .parsed(parsed):
            if !parsed.whatToReview.isEmpty {
                Card(title: "What to review") {
                    VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
                        ForEach(Array(parsed.whatToReview.enumerated()), id: \.offset) { _, line in
                            ReviewLineView(line: line)
                        }
                    }
                }
            }
            if !parsed.decisions.isEmpty {
                Card(title: "Decisions needed") {
                    VStack(alignment: .leading, spacing: DesignTokens.Space.s3) {
                        ForEach(Array(parsed.decisions.enumerated()), id: \.offset) { index, decision in
                            DecisionCard(number: index + 1, decision: decision, pick: picks.pick(index, in: decision), narrow: narrow) { option in
                                pick(option, index)
                            }
                        }
                    }
                }
            }
            if !parsed.whatChanged.isEmpty {
                Card(title: "What changed since the last brief") {
                    BulletList(lines: parsed.whatChanged)
                }
            }
            if !parsed.moves.isEmpty {
                Card(title: "How to approve, change or reject") {
                    VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
                        ForEach(Array(parsed.moves.enumerated()), id: \.offset) { _, move in
                            ChipText(text: move.text, lead: move.move.capitalized + ":")
                        }
                    }
                }
            }
        case let .raw(markdown):
            Card(title: "Review brief") {
                ChipText(text: markdown)
            }
        case nil:
            EmptyView()
        }
    }
}

/// A link as linked text, which opens in the browser like `Link` and also renders offscreen.
private struct LinkText: View {
    let label: String
    let url: URL

    var body: some View {
        Text(Self.attributed(label, url))
            .accessibilityAddTraits(.isLink)
    }

    static func attributed(_ label: String, _ url: URL) -> AttributedString {
        var text = AttributedString(label)
        text.link = url
        return text
    }
}

private struct ReviewLineView: View {
    let line: InboxReview.ReviewLine

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.s2) {
            Image(systemName: line.links.isEmpty ? "circle.fill" : "link")
                .imageScale(.small)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            if let link = line.links.first, line.text == link.label {
                LinkText(label: link.label, url: link.url)
            } else {
                VStack(alignment: .leading, spacing: DesignTokens.Space.s1) {
                    ChipText(text: line.text)
                    ForEach(line.links, id: \.self) { link in
                        LinkText(label: link.label, url: link.url).font(DesignTokens.TypeStyle.callout.font)
                    }
                }
            }
        }
        .font(DesignTokens.TypeStyle.body.font)
    }
}

/// C16: a plan's decision, its options as N7 cards (DD-4) with the recommended one marked and picked to start with.
/// A pick that differs from the recommendation turns Send Decisions on.
private struct DecisionCard: View {
    let number: Int
    let decision: InboxReview.Decision
    let pick: Int?
    var narrow = false
    let choose: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
            ChipText(text: decision.question, lead: "\(number).", font: DesignTokens.TypeStyle.rowTitle.nsFont)
            OptionCardList(
                title: "Decision \(number), \(decision.question)",
                cards: OptionCard.cards(for: decision),
                selected: pick,
                selectable: true,
                narrow: narrow,
                choose: choose
            )
            // A brief that names no recommended option still says what it recommends.
            if decision.initialPick == nil, let recommendation = decision.recommendation {
                ChipText(text: recommendation, lead: "Recommendation:", font: DesignTokens.TypeStyle.callout.nsFont, color: .secondaryLabelColor)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SubTicketsCard: View {
    let tickets: [InboxReview.SubTicket]

    var body: some View {
        Card(title: "Sub-tickets") {
            VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
                ForEach(Array(tickets.enumerated()), id: \.offset) { index, ticket in
                    HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.s2) {
                        Text("\(index + 1).").monospacedDigit().foregroundStyle(.secondary)
                        Text(ticket.identifier).font(DesignTokens.TypeStyle.rowTitle.font)
                        Text(ticket.title ?? "").lineLimit(1)
                        Spacer(minLength: DesignTokens.Space.s2)
                        if let state = ticket.state {
                            Text(state).font(DesignTokens.TypeStyle.callout.font).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}

/// D2b: CI, and QA with its report.
private struct ChecksCard: View {
    let pullRequest: InboxReview.PullRequest

    var body: some View {
        Card(title: "Checks") {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: DesignTokens.Space.s4, verticalSpacing: DesignTokens.Space.s2) {
                CheckRow(label: "CI", value: pullRequest.ci?.rawValue.capitalized ?? "Not seen yet", status: status(ci: pullRequest.ci))
                CheckRow(
                    label: "QA",
                    value: pullRequest.qaVerdict?.capitalized ?? "No report yet",
                    status: status(verdict: pullRequest.qaVerdict, good: ["pass"], bad: ["fail", "blocked"]),
                    link: pullRequest.qaReport.map { ("Open Report", $0) }
                )
            }
        }
    }

    private func status(ci: InboxReview.PullRequest.Result?) -> DesignTokens.Status? {
        switch ci {
        case .passed: .done
        case .failed: .problem
        case .pending: .working
        case nil: nil
        }
    }

    private func status(verdict: String?, good: [String], bad: [String]) -> DesignTokens.Status? {
        guard let verdict else { return nil }
        if good.contains(verdict) { return .done }
        if bad.contains(verdict) { return .problem }
        return .you
    }
}

private struct CheckRow: View {
    let label: String
    let value: String
    let status: DesignTokens.Status?
    var link: (String, URL)?

    var body: some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).frame(minWidth: 130, alignment: .leading)
            HStack(spacing: DesignTokens.Space.s2) {
                if let status {
                    Image(systemName: status.symbol).foregroundStyle(status.tint).accessibilityLabel(status.word)
                }
                Text(value).foregroundStyle(status == .problem ? AnyShapeStyle(DesignTokens.Status.problem.tint) : AnyShapeStyle(.primary))
                if let link { LinkText(label: link.0, url: link.1).font(DesignTokens.TypeStyle.callout.font) }
            }
        }
        .font(DesignTokens.TypeStyle.body.font)
        .accessibilityElement(children: .combine)
    }
}

/// D2c: the question first (N5), what happened and what waits (N6), then the options as cards (N7) and, on a request
/// the Inbox answers, the write-in (N11); an older request lists its numbered steps instead. The picked option, or
/// the write-in's words, is the answer the toolbar's Send Decision sends.
private struct ActionCards: View {
    let action: InboxReview.Action
    var picks = DecisionPicks()
    var pick: (Int) -> Void = { _ in }
    var writeIn: (String) -> Void = { _ in }
    /// True when the item carries an answerable request.
    var answerable = false
    var narrow = false
    @FocusState private var writeInFocused: Bool

    var body: some View {
        if let question = action.question {
            if action.options.isEmpty {
                Card(title: "Question") { ChipText(text: question) }
            } else {
                QuestionCallout(question: question)
            }
        }
        StoryCard(paragraphs: action.whyParagraphs, ifUnanswered: action.ifUnanswered)
        if !action.options.isEmpty {
            Card(title: "Options", hint: answerable && !narrow ? action.keyHint : nil) {
                OptionCardList(
                    title: "Options",
                    cards: OptionCard.cards(for: action, writeIn: answerable),
                    selected: answerable ? action.pickedIndex(picks) : nil,
                    selectable: answerable,
                    narrow: narrow,
                    showsKeys: answerable,
                    choose: pick
                )
                if answerable && action.isWriteIn(picks) {
                    WriteInField(initialText: picks.writeIn, commit: writeIn, focused: $writeInFocused)
                        .id(WriteInField.scrollID)
                }
            }
            // Picking the write-in, by a click or its number key, puts the keyboard in its field.
            .onChange(of: answerable && action.isWriteIn(picks)) { _, picked in writeInFocused = picked }
        }
        if !action.steps.isEmpty {
            Card(title: "Steps") {
                VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
                    ForEach(Array(action.steps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.s2) {
                            Text("\(index + 1).").monospacedDigit().foregroundStyle(.secondary)
                            ChipText(text: step)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }
}

/// N5: the decision's question under the title, labelled "Your decision", on `surface.raised` tinted with
/// `status.you` and a leading bar.
private struct QuestionCallout: View {
    let question: String

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s1) {
            Text("Your decision")
                .textCase(.uppercase)
                .font(DesignTokens.TypeStyle.label.font)
                .foregroundStyle(DesignTokens.Status.you.tint)
            ChipText(text: question, font: DecisionType.questionFont)
        }
        .padding(.vertical, DesignTokens.Space.s3)
        .padding(.horizontal, DesignTokens.Space.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            DesignTokens.Surface.raised.color
            DesignTokens.Status.you.tint.opacity(0.10)
        }
        .overlay(alignment: .leading) {
            DesignTokens.Status.you.tint.frame(width: 3)
        }
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.row, style: .continuous))
        // Its chips are links inside the question, so the callout contains them rather than reading as one.
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isHeader)
    }
}

/// N6: what happened, in at most two paragraphs, and what waits if nobody answers. Nothing is drawn without either.
private struct StoryCard: View {
    let paragraphs: [String]
    let ifUnanswered: String?

    var body: some View {
        if !paragraphs.isEmpty || ifUnanswered != nil {
            Card(title: "What happened") {
                VStack(alignment: .leading, spacing: DesignTokens.Space.s3) {
                    ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                        ChipText(text: paragraph)
                    }
                    if let ifUnanswered {
                        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.s2) {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundStyle(DesignTokens.Status.you.tint)
                                .accessibilityHidden(true)
                            ChipText(text: ifUnanswered, lead: "If you don't answer:")
                        }
                    }
                }
                .font(DesignTokens.TypeStyle.body.font)
            }
        }
    }
}

/// The type sizes of the decision review's new parts.
private enum DecisionType {
    /// N5's question.
    static let questionFont = NSFont.systemFont(ofSize: 16, weight: .semibold)
    /// N7's label.
    static let optionLabel = NSFont.systemFont(ofSize: 13.5, weight: .semibold)
    /// N8's text.
    static let tag = Font.system(size: 12)
    static let tagFont = NSFont.systemFont(ofSize: 12)
}

/// A decision's N7 cards stacked, one radio group for VoiceOver: each option reads "Option 1 of 3, its label,
/// recommended, selected", then its effect and its tags.
private struct OptionCardList: View {
    /// The group's name for VoiceOver.
    let title: String
    let cards: [OptionCard]
    let selected: Int?
    let selectable: Bool
    var narrow = false
    /// True when the number keys pick: each card shows its key.
    var showsKeys = false
    let choose: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
            ForEach(cards) { card in
                OptionCardView(card: card, selected: card.index == selected, selectable: selectable, narrow: narrow, showsKey: showsKeys && !narrow) {
                    choose(card.index)
                }
            }
        }
        .accessibilityRepresentation {
            Picker(title, selection: Binding(get: { selected ?? -1 }, set: choose)) {
                ForEach(cards) { card in
                    Text(card.accessibilityLabel(selected: card.index == selected)).tag(card.index)
                }
            }
            .pickerStyle(.radioGroup)
            .disabled(!selectable)
        }
    }
}

/// N7: one option, full width: a radio, the label on the first line with its Recommended badge and key, the effect
/// under the label, its trade-off tags (N8), and on the recommended card why. Picked, it takes an accent ring and tint.
private struct OptionCardView: View {
    let card: OptionCard
    let selected: Bool
    let selectable: Bool
    let narrow: Bool
    let showsKey: Bool
    let choose: () -> Void

    var body: some View {
        if selectable {
            Button(action: choose) { content }.buttonStyle(.plain)
        } else {
            content
        }
    }

    private var content: some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.s3) {
            if selectable {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
            }
            // The effect, tags and reason stack under the label, at its leading edge.
            VStack(alignment: .leading, spacing: DesignTokens.Space.s1) {
                HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.s2) {
                    ChipText(text: card.label, font: DecisionType.optionLabel, selectable: false)
                    if card.recommended && !narrow { RecommendedBadge() }
                    Spacer(minLength: DesignTokens.Space.s2)
                    if showsKey { KeyHint(number: card.number) }
                }
                if card.recommended && narrow { RecommendedBadge() }
                if let effect = card.effect {
                    ChipText(text: effect, color: .secondaryLabelColor, selectable: false)
                }
                if !card.tradeoffs.isEmpty {
                    VStack(alignment: .leading, spacing: DesignTokens.Space.s1) {
                        ForEach(Array(card.tradeoffs.enumerated()), id: \.offset) { _, tradeoff in
                            TradeoffTag(tradeoff: tradeoff)
                        }
                    }
                    .padding(.top, DesignTokens.Space.s1 / 2)
                }
                if let reason = card.reason {
                    ChipText(text: reason, lead: OptionCard.reasonLead, font: DesignTokens.TypeStyle.callout.nsFont, selectable: false)
                        .padding(.horizontal, DesignTokens.Space.s2)
                        .padding(.vertical, DesignTokens.Space.s1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: DesignTokens.Radius.mark, style: .continuous))
                        .padding(.top, DesignTokens.Space.s1)
                }
            }
        }
        .padding(DesignTokens.Space.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            selected ? AnyShapeStyle(Color.accentColor.opacity(0.07)) : AnyShapeStyle(DesignTokens.Surface.content.color),
            in: RoundedRectangle(cornerRadius: DesignTokens.Radius.row, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.row, style: .continuous)
                .strokeBorder(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(DesignTokens.Surface.separator.color), lineWidth: selected ? 2 : 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.row, style: .continuous))
    }
}

/// N11's field, under the write-in card once it is picked: a `TextEditor` three lines tall that grows with the
/// text to eight, then scrolls, over the hint that says how the agent reads it. The editor types into the field's own
/// draft, handed to `commit` on each change: bound straight to the window model, a redraw between fast keystrokes put
/// an older text back and lost what was typed.
private struct WriteInField: View {
    @State private var text: String
    var commit: (String) -> Void
    var focused: FocusState<Bool>.Binding
    @Environment(\.offscreenSnapshot) private var offscreenSnapshot

    /// The height of one line of `type.body`.
    private static let lineHeight = NSLayoutManager().defaultLineHeight(for: .systemFont(ofSize: NSFont.systemFontSize))
    /// The text view's own inset on each side of a line.
    private static let inset: CGFloat = 5
    /// The field's id in the review's scroll view, which scrolls to it once it is picked.
    static let scrollID = "write-in"

    init(initialText: String, commit: @escaping (String) -> Void, focused: FocusState<Bool>.Binding) {
        _text = State(initialValue: initialText)
        self.commit = commit
        self.focused = focused
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s1) {
            // A hidden copy of the text sizes the editor: at least three lines, at most eight.
            Text(text.isEmpty || text.hasSuffix("\n") ? text + " " : text)
                .font(DesignTokens.TypeStyle.body.font)
                .lineLimit(8)
                .padding(.horizontal, Self.inset)
                .frame(maxWidth: .infinity, minHeight: Self.lineHeight * 3, alignment: .topLeading)
                .hidden()
                .overlay(alignment: .topLeading) {
                    if offscreenSnapshot {
                        Text(text).font(DesignTokens.TypeStyle.body.font).padding(.horizontal, Self.inset)
                    } else {
                        editor
                    }
                }
                .padding(DesignTokens.Space.s2)
                .background(DesignTokens.Surface.content.color, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.row, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.row, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 1)
                )
            Text(OptionCard.writeInHint)
                .font(DesignTokens.TypeStyle.callout.font)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityHidden(true)
        }
    }

    private var editor: some View {
        TextEditor(text: $text)
            .font(DesignTokens.TypeStyle.body.font)
            .scrollContentBackground(.hidden)
            .onChange(of: text) { _, text in commit(text) }
            .focused(focused)
            .accessibilityLabel(OptionCard.writeInLabel)
            .accessibilityHint(OptionCard.writeInHint)
    }
}

/// The word "Recommended" in an accent capsule.
private struct RecommendedBadge: View {
    var body: some View {
        Text("Recommended")
            .font(DesignTokens.TypeStyle.label.font)
            .padding(.horizontal, DesignTokens.Space.s2)
            .background(Color.accentColor.opacity(0.18), in: Capsule())
            .fixedSize()
    }
}

/// The number key that picks an option, as a key cap.
private struct KeyHint: View {
    let number: Int

    var body: some View {
        Text("\(number)")
            .font(DesignTokens.TypeStyle.caption.font.monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(minWidth: 18, minHeight: 18)
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.mark, style: .continuous)
                    .strokeBorder(DesignTokens.Surface.separator.color)
            )
            .help("Press \(number) to pick this option")
    }
}

/// N8: what an option gains, costs or risks, as its symbol and words; the text wraps.
private struct TradeoffTag: View {
    let tradeoff: InboxReview.Action.Tradeoff

    var body: some View {
        Label {
            ChipText(text: tradeoff.text, font: DecisionType.tagFont, selectable: false)
        } icon: {
            Image(systemName: tradeoff.kind.symbol).foregroundStyle(tradeoff.kind.status.tint)
        }
        .font(DecisionType.tag)
        .labelStyle(.titleAndIcon)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(tradeoff.kind.word): \(tradeoff.text)")
    }
}

/// N9: where the item's ticket sits, last in its review: its parent and progress (N10), its pull request, the tickets
/// connected to it, what answering unblocks and the calls already made. Two columns, labels above values in a narrow
/// pane. Its chips find the context's tickets too.
private struct ContextCardView: View {
    let card: ContextCard
    let narrow: Bool

    var body: some View {
        Card(title: ContextCard.title) {
            if narrow {
                VStack(alignment: .leading, spacing: DesignTokens.Space.s3) {
                    ForEach(rows, id: \.label) { row in
                        VStack(alignment: .leading, spacing: DesignTokens.Space.s1) {
                            ContextLabel(text: row.label)
                            row.value
                        }
                    }
                }
            } else {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: DesignTokens.Space.s4, verticalSpacing: DesignTokens.Space.s3) {
                    ForEach(rows, id: \.label) { row in
                        GridRow {
                            ContextLabel(text: row.label)
                            row.value
                        }
                    }
                }
            }
        }
        .font(DesignTokens.TypeStyle.body.font)
        .environment(\.mentionReferences, card.references)
    }

    private var rows: [(label: String, value: AnyView)] {
        var rows: [(label: String, value: AnyView)] = []
        if let partOf = card.partOf {
            rows.append(("Part of", AnyView(VStack(alignment: .leading, spacing: DesignTokens.Space.s1) {
                ChipText(text: partOf.text)
                if let progress = partOf.progress { ProgressStripView(strip: progress) }
            })))
        }
        if let work = card.work {
            rows.append(("Its work", AnyView(ChipText(text: work))))
        }
        if !card.connected.isEmpty {
            rows.append(("Connected", AnyView(VStack(alignment: .leading, spacing: DesignTokens.Space.s1) {
                ForEach(Array(card.connected.enumerated()), id: \.offset) { _, connection in
                    HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.s2) {
                        ChipText(text: connection.identifier).fixedSize()
                        if let stage = connection.stage { StatusBadge(status: stage.status, word: stage.word).fixedSize() }
                        ChipText(text: connection.relation, color: .secondaryLabelColor)
                    }
                }
            })))
        }
        if let answer = card.answer {
            rows.append(("Your answer", AnyView(ChipText(text: answer))))
        }
        if !card.earlierCalls.isEmpty {
            rows.append(("Earlier calls", AnyView(VStack(alignment: .leading, spacing: DesignTokens.Space.s1) {
                ForEach(Array(card.earlierCalls.enumerated()), id: \.offset) { _, call in
                    HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.s2) {
                        if let time = call.time {
                            Text(time).monospacedDigit().foregroundStyle(.secondary).fixedSize()
                        }
                        ChipText(text: call.text)
                    }
                }
            })))
        }
        return rows
    }
}

/// A row's label in the context card (N9).
private struct ContextLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.leading)
            .fixedSize()
    }
}

/// N10: one 14 × 5 pt segment per sub-ticket in landing order, coloured by its state, and "4 of 7 done" beside it;
/// one element for VoiceOver, "4 of 7 sub-tickets done".
private struct ProgressStripView: View {
    let strip: ProgressStrip

    var body: some View {
        HStack(alignment: .center, spacing: DesignTokens.Space.s2) {
            HStack(spacing: ProgressStrip.gap) {
                ForEach(Array(strip.segments.enumerated()), id: \.offset) { _, segment in
                    RoundedRectangle(cornerRadius: ProgressStrip.segmentHeight / 2, style: .continuous)
                        .fill(segment.color.color)
                        .frame(minWidth: 3, maxWidth: ProgressStrip.segmentWidth)
                        .frame(height: ProgressStrip.segmentHeight)
                }
            }
            .frame(maxWidth: ProgressStrip.segmentWidth * Double(strip.segments.count) + ProgressStrip.gap * Double(max(strip.segments.count - 1, 0)))
            Text(strip.line)
                .font(DesignTokens.TypeStyle.callout.font)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .fixedSize()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(strip.accessibilityLabel)
    }
}

/// D2d: what the quality gate found, its score and round, its questions, and what happens next.
private struct ClarifyCards: View {
    let clarify: InboxReview.Clarify

    var body: some View {
        Card(title: "What the quality gate found") {
            VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
                if let found = clarify.found { ChipText(text: found) }
                HStack(spacing: DesignTokens.Space.s4) {
                    if let score = clarify.scoreLine { Label("Score \(score)", systemImage: "gauge.with.needle") }
                    if let round = clarify.roundLine { Label(round, systemImage: "arrow.trianglehead.2.clockwise") }
                }
                .font(DesignTokens.TypeStyle.callout.font)
                .foregroundStyle(.secondary)
            }
        }
        if !clarify.questions.isEmpty {
            Card(title: "Its questions") { BulletList(lines: clarify.questions) }
        }
        Card(title: "What happens next") { Text(clarify.nextLine) }
    }
}

/// A ticket an access hold pauses in place: why it waits, and what clears it. The Unblock in the toolbar lifts it.
private struct BlockedCards: View {
    let blocked: InboxReview.Blocked

    var body: some View {
        Card(title: "Why it is blocked") {
            VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
                if let reason = blocked.reason { ChipText(text: reason) }
                ChipText(text: blocked.nextLine, font: DesignTokens.TypeStyle.callout.nsFont, color: .secondaryLabelColor)
            }
        }
    }
}

private struct BulletList: View {
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.s2) {
                    Text("•").foregroundStyle(.secondary).accessibilityHidden(true)
                    ChipText(text: line)
                }
            }
        }
    }
}
