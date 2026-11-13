import SwiftUI
import SymphonyBarCore

/// A review's scroll view that starts where the review was left, and keeps where it is. A chip the keyboard moves to
/// scrolls the review through its position: the scroll view keeps its offset itself, and its next layout puts back a
/// scroll made from AppKit alone (the write-in, picked last, back at the bottom). Offsets count from the review's top,
/// below the toolbar, as its position does.
struct RememberedScroll: ViewModifier {
    let offset: Double?
    let remember: (Double) -> Void
    @State private var position = ScrollPosition()
    /// The offset the scroll view reported last, or the one a chip's scroll goes to; kept where a scroll redraws
    /// nothing.
    @State private var reported = ReportedOffset()

    func body(content: Content) -> some View {
        content
            .scrollPosition($position)
            .onScrollGeometryChange(for: Double.self) {
                InboxScrollOffsets.fromTop(contentOffset: $0.contentOffset.y, topInset: $0.contentInsets.top)
            } action: { _, offset in
                reported.y = offset
                remember(offset)
            }
            .environment(\.scrollReview, ScrollReviewAction { distance in
                // From where the last scroll goes, so a second Tab before the scroll view reports adds to the first.
                reported.y += distance
                position.scrollTo(y: reported.y)
            })
            .onAppear {
                guard let offset else { return }
                // Once the review is laid out.
                DispatchQueue.main.async { position.scrollTo(y: offset) }
            }
    }
}

/// A review's offset, in a box: setting it redraws nothing.
private final class ReportedOffset {
    var y: Double = 0
}

/// D2e in the drawer: good news. A scope that hides items says so (P6).
struct InboxEmpty: View {
    let hiddenLine: String?

    var body: some View {
        ContentUnavailableView {
            Label(InboxList.emptyTitle, systemImage: "tray")
        } description: {
            if let hiddenLine { Text(hiddenLine) }
        }
    }
}

// MARK: - C15: the review

/// The review of one item: its header, its actions, and its sections by kind.
struct InboxReviewBody: View {
    let item: InboxItem
    var picks = DecisionPicks()
    var pick: (Int, Int) -> Void = { _, _ in }
    /// Keeps a write-in's text: (text, decision).
    var writeIn: (String, Int) -> Void = { _, _ in }
    let perform: (InboxCommand) -> Void
    var openTicket: () -> Void = {}
    /// A click on a ticket or pull request chip in the review's text, and a ⌘-click.
    var openMention: (Mention) -> Void = { _ in }
    var openMentionDirectly: (Mention) -> Void = { _ in }
    /// True in a narrow pane: an option card's Recommended badge goes under its label, the key hints hide, and the
    /// context card puts its labels above their values.
    var narrow = false
    /// The context card's clock, Symphony's: an earlier call today shows its time only, and its situation ages.
    var now = Date()
    /// What the watcher found behind its decision (S16), above the options.
    var evidence: WatcherEvidence?
    /// Symphony's state, for the context card's situation lines.
    var state: StateSnapshot?

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s4) {
            ReviewHeader(item: item, toolbar: InboxToolbar.toolbar(for: item, picks: picks), perform: perform, openTicket: openTicket)
            switch item.kind {
            case .plan:
                if let warning = item.review.unappliedAnswersWarning { PlanWarning(text: warning) }
                if let warning = item.review.unaskedChoicesWarning { PlanWarning(text: warning) }
                PlanQuestions(questions: item.review.questions, picks: picks, pick: pick, writeIn: writeIn, narrow: narrow)
                BriefSections(brief: item.review.brief)
                if !item.review.subTickets.isEmpty { SubTicketsCard(tickets: item.review.subTickets) }
            case .pr:
                if let pullRequest = item.review.pullRequest { ChecksCard(pullRequest: pullRequest) }
                BriefSections(brief: item.review.brief)
            case .action:
                // D2c: the Question block (the shared Question's callout, story, option cards and own words); the
                // toolbar's Send Decision sends its answer, so the block draws no Send of its own.
                if let action = item.review.action {
                    QuestionBlock(
                        action: action, picks: picks, pick: { pick($0, 0) }, writeIn: { writeIn($0, 0) }, answerable: item.answerable, narrow: narrow
                    ) {
                        if let evidence { EvidenceCard(evidence: evidence) }
                    }
                }
            case .clarify:
                if let clarify = item.review.clarify { ClarifyCards(clarify: clarify) }
            case .blocked:
                if let blocked = item.review.blocked { BlockedCards(blocked: blocked) }
            case .waiting:
                if let wait = item.review.blocked { WaitingCard(wait: wait) }
            }
            if let context = ContextCard(item: item, now: now, state: state) {
                ContextCardView(card: context, narrow: narrow, reference: now)
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
        Badge(status: item.kind.status, word: item.kindWord)
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

    var body: some View {
        HStack(alignment: .top, spacing: DesignTokens.Space.s2) {
            ForEach(Array(toolbar.buttons.enumerated()), id: \.offset) { index, button in
                if index == 0 {
                    Button(button.command.title) { perform(button.command) }
                        // ⌘↩ sends a decision from anywhere in the Inbox.
                        .keyboardShortcut(button.command == .move(.decide) ? KeyboardShortcut(.return, modifiers: .command) : nil)
                        .directorButton(.primary, disabledReason: button.reason)
                } else {
                    Button(button.command.title) { perform(button.command) }
                        .directorButton(disabledReason: button.reason)
                }
            }
            if !toolbar.overflow.isEmpty {
                MenuButton("More", glyph: "ellipsis", quiet: true, help: "More actions") {
                    toolbar.overflow.map { command in MenuItem(command.title) { perform(command) } }
                }
            }
        }
        .fixedSize()
    }
}

/// A brief in its parts, or as text when it didn't parse. A plan's questions are not the brief's: they are its requests
/// (`PlanQuestions`).
private struct BriefSections: View {
    let brief: InboxReview.Brief?

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
                        LinkText(label: link.label, url: link.url).font(DesignTokens.TypeStyle.secondary.font)
                    }
                }
            }
        }
        .font(DesignTokens.TypeStyle.body.font)
    }
}

/// A warning on a plan under review, above its questions.
private struct PlanWarning: View {
    let text: String

    var body: some View {
        // Only the triangle takes status.you: orange text on white is below 4.5:1 in light.
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.s2) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(DesignTokens.Status.you.tint)
                .accessibilityHidden(true)
            Text(text)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(DesignTokens.TypeStyle.secondary.font)
    }
}

/// C16: a plan's open questions, each a request its plan run raised: what it asks, what happened and what waits if
/// nobody answers, then its options as N7 cards with the recommended one picked to start with, and the write-in
/// (N11) for an answer in the Director's own words. Send Decisions sends every answer.
private struct PlanQuestions: View {
    let questions: [InboxReview.Action]
    var picks = DecisionPicks()
    var pick: (Int, Int) -> Void = { _, _ in }
    var writeIn: (String, Int) -> Void = { _, _ in }
    var narrow = false

    var body: some View {
        ForEach(Array(questions.enumerated()), id: \.offset) { index, question in
            PlanQuestionCard(
                index: index,
                count: questions.count,
                question: question,
                picks: picks,
                pick: { pick($0, index) },
                writeIn: { writeIn($0, index) },
                narrow: narrow
            )
        }
    }
}

private struct PlanQuestionCard: View {
    let index: Int
    let count: Int
    let question: InboxReview.Action
    let picks: DecisionPicks
    let pick: (Int) -> Void
    let writeIn: (String) -> Void
    var narrow = false
    @FocusState private var writeInFocused: Bool

    private var picked: Int? { question.decision.flatMap { picks.pick(index, in: $0) } }
    private var writeInPicked: Bool { picked == question.writeInIndex }

    var body: some View {
        Card(title: count == 1 ? "Your decision" : "Your decision \(index + 1) of \(count)") {
            VStack(alignment: .leading, spacing: DesignTokens.Space.s3) {
                if let text = question.question {
                    ChipText(text: text, font: DecisionType.questionFont)
                        .accessibilityAddTraits(.isHeader)
                }
                ForEach(Array(question.whyParagraphs.enumerated()), id: \.offset) { _, paragraph in
                    ChipText(text: paragraph)
                }
                if let ifUnanswered = question.ifUnanswered {
                    HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.s2) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(DesignTokens.Status.you.tint)
                            .accessibilityHidden(true)
                        ChipText(text: ifUnanswered, lead: "If you don't answer:")
                    }
                }
                OptionCardList(
                    title: "Decision \(index + 1), \(question.question ?? "")",
                    cards: OptionCard.cards(for: question, writeIn: true),
                    selected: picked,
                    selectable: true,
                    narrow: narrow,
                    choose: pick
                )
                if writeInPicked {
                    WriteInField(initialText: picks.writeIns[index] ?? "", commit: writeIn, focused: $writeInFocused)
                }
            }
            .font(DesignTokens.TypeStyle.body.font)
        }
        // Picking the write-in puts the keyboard in its field.
        .onChange(of: writeInPicked) { _, picked in writeInFocused = picked }
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
                            Text(state).font(DesignTokens.TypeStyle.secondary.font).foregroundStyle(.secondary)
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
                if let link { LinkText(label: link.0, url: link.1).font(DesignTokens.TypeStyle.secondary.font) }
            }
        }
        .font(DesignTokens.TypeStyle.body.font)
        .accessibilityElement(children: .combine)
    }
}

/// S16: what the PR and CI watcher found behind its decision: the checks, the files and the error lines.
private struct EvidenceCard: View {
    let evidence: WatcherEvidence

    var body: some View {
        Card(title: WatcherEvidence.title) {
            VStack(alignment: .leading, spacing: DesignTokens.Space.s3) {
                Text(evidence.subject)
                    .font(DesignTokens.TypeStyle.rowTitle.font)
                    .help(evidence.help)
                ForEach(Array(evidence.rows.enumerated()), id: \.offset) { _, row in
                    VStack(alignment: .leading, spacing: DesignTokens.Space.s1) {
                        Text(row.label)
                            .font(DesignTokens.TypeStyle.secondary.font)
                            .foregroundStyle(.secondary)
                        ForEach(Array(row.values.enumerated()), id: \.offset) { _, value in
                            Text(value)
                                .font(row.monospaced ? DesignTokens.TypeStyle.mono.font : DesignTokens.TypeStyle.body.font)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(row.accessibilityLabel)
                }
            }
        }
    }
}

/// N9: where the item's ticket sits, last in its review: its situation line (C31), its parent and progress (N10), its
/// pull request, the tickets
/// connected to it, what answering unblocks and the calls already made. Two columns, labels above values in a narrow
/// pane. Its chips find the context's tickets too.
private struct ContextCardView: View {
    let card: ContextCard
    let narrow: Bool
    var reference = Date()

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
        if let situation = card.situation {
            rows.append(("Now", AnyView(SituationLine(situation, reference: reference, size: .compact))))
        }
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
                        if let situation = connection.situation {
                            VStack(alignment: .leading, spacing: DesignTokens.Space.s1 / 2) {
                                SituationLine(situation, reference: reference, size: .compact)
                                ChipText(text: connection.relation, color: .secondaryLabelColor)
                            }
                        } else {
                            if let stage = connection.stage { Badge(status: stage.status, word: stage.word).fixedSize() }
                            ChipText(text: connection.relation, color: .secondaryLabelColor)
                        }
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

/// N10: the progress strip (C51) of the parent's sub-tickets in landing order, and "4 of 7 done" beside it; one element
/// for VoiceOver, "4 of 7 sub-tickets done", then its counts. `header` draws the taller strip of an epic's header on
/// Initiatives, up to its wider width.
struct ProgressStripView: View {
    let strip: SubTicketStrip
    var header = false

    var body: some View {
        HStack(alignment: .center, spacing: DesignTokens.Space.s2) {
            if header {
                ProgressStrip(strip.items, height: DesignTokens.ProgressStrip.headerHeight, label: strip.accessibilityLabel)
                    .frame(maxWidth: DesignTokens.ProgressStrip.headerMaxWidth)
            } else {
                ProgressStrip(strip.items, label: strip.accessibilityLabel)
                    .frame(width: DesignTokens.ProgressStrip.compactWidth)
            }
            Text(strip.line)
                .textStyle(.secondary)
                .foregroundStyle(DesignTokens.TextColor.secondary.color)
                .monospacedDigit()
                .fixedSize()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ProgressStrip.accessibilityLabel(strip.items, label: strip.accessibilityLabel))
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
                .font(DesignTokens.TypeStyle.secondary.font)
                .foregroundStyle(.secondary)
            }
        }
        if !clarify.questions.isEmpty {
            Card(title: "Its questions") { BulletList(lines: clarify.questions) }
        }
        Card(title: "What happens next") { Text(clarify.nextLine) }
    }
}

/// A ticket an access hold pauses in place: why it waits, one line per pause reason ("Stopped by you"), and what
/// the toolbar's Unblock, Release or Restart does.
private struct BlockedCards: View {
    let blocked: InboxReview.Blocked

    var body: some View {
        Card(title: "Why it is blocked") {
            VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
                if blocked.reasonLines.count > 1 {
                    BulletList(lines: blocked.reasonLines)
                } else if let line = blocked.reasonLines.first {
                    ChipText(text: line)
                }
                ChipText(text: blocked.nextLine, font: DesignTokens.TypeStyle.secondary.nsFont, color: .secondaryLabelColor)
            }
        }
    }
}

/// A ticket waiting on CI: what it waits on, and that it moves on by itself. It offers no move.
private struct WaitingCard: View {
    let wait: InboxReview.Blocked

    var body: some View {
        Card(title: "What it waits on") {
            VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
                if let reason = wait.reason { ChipText(text: reason) }
                ChipText(text: wait.waitLine, font: DesignTokens.TypeStyle.secondary.nsFont, color: .secondaryLabelColor)
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
