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
                perform: { model.perform($0, on: $1) },
                openOverview: { model.show(.overview) }
            )
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
    let perform: (InboxCommand, InboxItem) -> Void
    let openOverview: () -> Void

    var body: some View {
        if list.isEmpty {
            InboxEmpty(hiddenLine: list.hiddenLine, openOverview: openOverview)
        } else {
            HStack(spacing: 0) {
                InboxListColumn(list: list, selection: $selection, picks: picks, perform: perform)
                    .frame(width: DesignTokens.Layout.listColumnWidth)
                    .background(DesignTokens.Surface.content.color)
                Divider()
                if let item = list.selection(selection) {
                    ScrollView {
                        InboxReviewBody(
                            item: item,
                            picks: picks(item.id),
                            pick: { option, decision in pick(option, decision, item.id) },
                            perform: { perform($0, item) }
                        )
                    }
                    // A new item starts with its own picks (the recommended options).
                    .id(item.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
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
    @FocusState private var focused: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                InboxListRows(list: list, selected: list.selection(selection)?.id) { selection = $0 }
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
                        .onTapGesture { select(item.id) }
                        .accessibilityAction { select(item.id) }
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
    let perform: (InboxCommand) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s4) {
            ReviewHeader(item: item, toolbar: InboxToolbar.toolbar(for: item, picks: picks), perform: perform)
            switch item.kind {
            case .plan:
                BriefSections(brief: item.review.brief, picks: picks, pick: pick)
                if !item.review.subTickets.isEmpty { SubTicketsCard(tickets: item.review.subTickets) }
            case .pr:
                if let pullRequest = item.review.pullRequest { ChecksCard(pullRequest: pullRequest) }
                BriefSections(brief: item.review.brief)
            case .finalVerification:
                BriefSections(brief: item.review.brief)
            case .action:
                if let action = item.review.action { ActionCards(action: action) }
            case .clarify:
                if let clarify = item.review.clarify { ClarifyCards(clarify: clarify) }
            }
        }
        .padding(DesignTokens.Space.s5)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ReviewHeader: View {
    let item: InboxItem
    let toolbar: InboxToolbar
    let perform: (InboxCommand) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
            HStack(spacing: DesignTokens.Space.s2) {
                StatusBadge(status: .you, word: item.kind.word)
                if let age = item.age {
                    Label("Waiting \(age)", systemImage: "clock")
                        .font(DesignTokens.TypeStyle.label.font)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                if let state = item.state {
                    Text(state)
                        .font(DesignTokens.TypeStyle.label.font)
                        .padding(.horizontal, DesignTokens.Space.s2)
                        .padding(.vertical, DesignTokens.Space.s1 / 2)
                        .overlay(Capsule().strokeBorder(DesignTokens.Surface.separator.color))
                }
                if let repo = item.repoKey {
                    Text(repo).font(DesignTokens.TypeStyle.label.font).foregroundStyle(.secondary)
                }
                Spacer(minLength: DesignTokens.Space.s2)
                ActionButtons(toolbar: toolbar, perform: perform)
            }
            Text([item.identifier, item.title].compactMap { $0 }.joined(separator: " "))
                .font(DesignTokens.TypeStyle.sentence.font)
                .textSelection(.enabled)
                .accessibilityAddTraits(.isHeader)
            Text(item.ask)
                .font(DesignTokens.TypeStyle.body.font)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }
}

/// The review's actions (P4): the first is the prominent default (Open PR while a check is red, D2b), and the ⋯
/// menu holds the rest. A move only opens its sheet.
private struct ActionButtons: View {
    let toolbar: InboxToolbar
    let perform: (InboxCommand) -> Void

    var body: some View {
        HStack(spacing: DesignTokens.Space.s2) {
            ForEach(Array(toolbar.buttons.enumerated()), id: \.offset) { index, button in
                if index == 0 {
                    Button(button.command.title) { perform(button.command) }
                        .buttonStyle(.borderedProminent)
                        .disabled(!button.enabled)
                } else {
                    Button(button.command.title) { perform(button.command) }
                        .disabled(!button.enabled)
                }
            }
            if !toolbar.overflow.isEmpty {
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
                            DecisionCard(number: index + 1, decision: decision, pick: picks.pick(index, in: decision)) { option in
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
                            Text("\(Text(move.move.capitalized + ": ").bold())\(move.text)")
                                .font(DesignTokens.TypeStyle.body.font)
                        }
                    }
                }
            }
            if let check = parsed.supervisorCheck {
                Card(title: "Supervisor check") {
                    Text(check).font(DesignTokens.TypeStyle.mono.font).textSelection(.enabled)
                }
            }
        case let .raw(markdown):
            Card(title: "Review brief") {
                Text(markdown)
                    .font(DesignTokens.TypeStyle.body.font)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
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
                    Text(line.text).textSelection(.enabled)
                    ForEach(line.links, id: \.self) { link in
                        LinkText(label: link.label, url: link.url).font(DesignTokens.TypeStyle.callout.font)
                    }
                }
            }
        }
        .font(DesignTokens.TypeStyle.body.font)
    }
}

/// C16: a decision with its options as a radio group, the recommended one marked and picked to start with. A pick
/// that differs from the recommendation turns Send Decisions on.
private struct DecisionCard: View {
    let number: Int
    let decision: InboxReview.Decision
    let pick: Int?
    let choose: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
            Text("\(number). \(decision.question)").font(DesignTokens.TypeStyle.rowTitle.font)
            Picker(decision.question, selection: Binding(get: { pick ?? -1 }, set: choose)) {
                ForEach(Array(decision.options.enumerated()), id: \.offset) { index, option in
                    HStack(spacing: DesignTokens.Space.s2) {
                        Text(option)
                        if index == decision.recommended {
                            Text("Recommended")
                                .font(DesignTokens.TypeStyle.label.font)
                                .padding(.horizontal, DesignTokens.Space.s2)
                                .background(Color.accentColor.opacity(0.18), in: Capsule())
                        }
                    }
                    .tag(index)
                    .accessibilityLabel(index == decision.recommended ? "option \(index + 1), \(option), recommended" : "option \(index + 1), \(option)")
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            if let recommendation = decision.recommendation {
                Text("Recommendation: \(recommendation)")
                    .font(DesignTokens.TypeStyle.callout.font)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(DesignTokens.Space.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.Surface.raised.color, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.row, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Decision \(number), \(decision.question)")
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

/// D2b: CI, Auto Review QA with its report, the gate's verdict and mode, and the change's size.
private struct ChecksCard: View {
    let pullRequest: InboxReview.PullRequest

    var body: some View {
        Card(title: "Checks") {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: DesignTokens.Space.s4, verticalSpacing: DesignTokens.Space.s2) {
                CheckRow(label: "CI", value: pullRequest.ci?.rawValue.capitalized ?? "Not seen yet", status: status(ci: pullRequest.ci))
                CheckRow(
                    label: "Auto Review QA",
                    value: pullRequest.qaVerdict?.capitalized ?? "No report yet",
                    status: status(verdict: pullRequest.qaVerdict, good: ["pass"], bad: ["fail", "blocked"]),
                    link: pullRequest.qaReport.map { ("Open Report", $0) }
                )
                CheckRow(
                    label: "Acceptance gate",
                    value: pullRequest.gateVerdict.map { verdict in
                        [verdict.capitalized, pullRequest.gateMode.map { "\($0) mode" }].compactMap { $0 }.joined(separator: " · ")
                    } ?? "No verdict",
                    status: status(verdict: pullRequest.gateVerdict, good: ["approve"], bad: ["rework"])
                )
                CheckRow(label: "Change", value: pullRequest.changeLine ?? "Not measured yet", status: nil)
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

/// D2c: why, the numbered steps or the options, about how long, and what it unblocks.
private struct ActionCards: View {
    let action: InboxReview.Action

    var body: some View {
        if let why = action.why {
            Card(title: "Why") { Text(why).textSelection(.enabled) }
        }
        if let question = action.question {
            Card(title: "Question") {
                VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
                    Text(question).textSelection(.enabled)
                    ForEach(Array(action.options.enumerated()), id: \.offset) { index, option in
                        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.s2) {
                            Text("\(index + 1).").monospacedDigit().foregroundStyle(.secondary)
                            Text(option.label).bold()
                            if option.recommended {
                                Text("Recommended")
                                    .font(DesignTokens.TypeStyle.label.font)
                                    .padding(.horizontal, DesignTokens.Space.s2)
                                    .background(Color.accentColor.opacity(0.18), in: Capsule())
                            }
                            if let effect = option.effect { Text(effect).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
        }
        if !action.steps.isEmpty {
            Card(title: "Steps") {
                VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
                    ForEach(Array(action.steps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.s2) {
                            Text("\(index + 1).").monospacedDigit().foregroundStyle(.secondary)
                            Text(step).textSelection(.enabled)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
        if action.timeLine != nil || action.unblocks != nil {
            Card(title: "Time and what it unblocks") {
                VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
                    if let time = action.timeLine { Label(time, systemImage: "clock") }
                    if let unblocks = action.unblocks { Label("Unblocks \(unblocks)", systemImage: "lock.open") }
                }
            }
        }
    }
}

/// D2d: what the quality gate found, its score and round, its questions, and what happens next.
private struct ClarifyCards: View {
    let clarify: InboxReview.Clarify

    var body: some View {
        Card(title: "What the quality gate found") {
            VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
                if let found = clarify.found { Text(found).textSelection(.enabled) }
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

private struct BulletList: View {
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.s2) {
                    Text("•").foregroundStyle(.secondary).accessibilityHidden(true)
                    Text(line).textSelection(.enabled)
                }
            }
        }
    }
}
