import AppKit
import SwiftUI
import SymphonyBarCore

// MARK: - The window model's peek (N4)

extension SymphonyWindowModel {
    /// A chip in the review: its peek, beside the decision, whose picks stay as they are.
    func openPeek(_ mention: Mention) {
        peek.open(PeekEntry(mention))
        readPeek()
    }

    /// A chip inside the peek: its page on top, the back arrow and ⌘[ return.
    func pushPeek(_ mention: Mention) {
        peek.push(PeekEntry(mention))
        readPeek()
    }

    /// ⌘-click or ⌘Return: the ticket's page (D3), from which ⌘[ returns to the decision, or the pull request on
    /// GitHub.
    func openMentionDirectly(_ mention: Mention) {
        ChipText.open(mention, openTicket: openTicket, openURL: onOpenURL)
    }

    /// Esc, Close, the toolbar's toggle.
    func closePeek() {
        peek.close()
    }

    /// The toolbar's inspector toggle and ⌥⌘I on the Inbox.
    func togglePeek() {
        peek.toggle()
        readPeek()
    }

    /// What a peek page shows: a ticket's page from everything the window has read, or a pull request's, or the line
    /// for a mention Symphony can't see.
    func peekContent(_ entry: PeekEntry) -> PeekContent {
        guard case let .ticket(ticket) = entry.reference else {
            return .other(ReferencePopover(key: entry.key, kind: entry.kind, reference: entry.reference))
        }
        let sources = PeekSources(
            inbox: inbox?.items ?? [],
            initiatives: initiatives?.initiatives ?? [],
            state: client.stateJSON,
            issue: peekIssues[ticket.identifier]
        )
        let references = inboxList?.selection(inboxSelection)?.references ?? [:]
        return .ticket(TicketPeek(ticket, references: references, sources: sources, now: Date()))
    }

    /// What the peek's buttons and chips do.
    var peekActions: PeekActions {
        PeekActions(
            back: { [weak self] in self?.goBack() },
            close: { [weak self] in self?.closePeek() },
            push: { [weak self] in self?.pushPeek($0) },
            openDirectly: { [weak self] in self?.openMentionDirectly($0) },
            openTicketPage: { [weak self] in self?.openTicket($0) },
            openURL: { [weak self] in self?.onOpenURL($0) }
        )
    }

    /// Reads the peeked ticket's `/api/v1/:issue_identifier`, the ticket page's endpoint, when it opens and after each
    /// state poll while it shows: it says whether Symphony tracks the ticket, and what it does now.
    func readPeek() {
        guard peek.isShown, let identifier = peek.current?.ticketIdentifier, !readingPeek, state.countsKnown else { return }
        readingPeek = true
        Task {
            if case let .loaded(data) = await client.get(TicketPage.issuePath(identifier)) {
                peekIssues[identifier] = data
            } else {
                peekIssues[identifier] = nil
            }
            readingPeek = false
        }
    }
}

/// A peek page's content.
enum PeekContent: Equatable {
    case ticket(TicketPeek)
    /// A pull request (N3's figures), or a mention Symphony can't see.
    case other(ReferencePopover)

    /// The mentions its text holds, for its chips.
    var references: [String: Reference] {
        if case let .ticket(peek) = self { return peek.references }
        return [:]
    }
}

/// What the peek's buttons and chips do.
struct PeekActions {
    var back: () -> Void = {}
    var close: () -> Void = {}
    /// A chip inside the peek: its page on top.
    var push: (Mention) -> Void = { _ in }
    /// ⌘-click on a chip inside the peek.
    var openDirectly: (Mention) -> Void = { _ in }
    var openTicketPage: (String) -> Void = { _ in }
    var openURL: (URL) -> Void = { _ in }
}

// MARK: - Where it shows

/// N4 beside the review in the window's inspector column, or as a sheet over the window when the detail would be under
/// 560 pt with the inspector open. The review under it is left alone: the same item, picks and scroll position.
struct PeekPresenter: ViewModifier {
    @ObservedObject var model: SymphonyWindowModel
    @State private var presentation = PeekPresentation.inspector

    func body(content: Content) -> some View {
        content
            // While the peek is closed this is the choice it opens with.
            .onGeometryChange(for: Double.self) { $0.size.width } action: { width in
                presentation = PeekPresentation.choose(detailWidth: width, inspectorShown: shows(.inspector))
            }
            .inspector(isPresented: binding(.inspector)) {
                PeekView(model: model)
                    .inspectorColumnWidth(
                        min: PeekPresentation.minInspectorWidth,
                        ideal: PeekPresentation.idealInspectorWidth,
                        max: PeekPresentation.maxInspectorWidth
                    )
            }
            .sheet(isPresented: binding(.sheet)) {
                PeekView(model: model)
                    .frame(width: PeekPresentation.maxInspectorWidth, height: DesignTokens.Layout.narrowReviewWidth)
            }
    }

    private func shows(_ place: PeekPresentation) -> Bool { model.peek.isShown && presentation == place }

    /// Shown in `place`; a dismissal there (a sheet's Esc) closes the peek, a move to the other place doesn't.
    private func binding(_ place: PeekPresentation) -> Binding<Bool> {
        Binding(
            get: { shows(place) },
            set: { shown in
                if !shown, presentation == place { model.closePeek() }
            }
        )
    }
}

/// N4: a `NavigationStack` of peek pages, the first opened from the review, the others pushed by its chips.
struct PeekView: View {
    @ObservedObject var model: SymphonyWindowModel

    var body: some View {
        NavigationStack(path: $model.peek.path) {
            Group {
                if let root = model.peek.root { page(root, pushed: false) }
            }
            .navigationDestination(for: PeekEntry.self) { page($0, pushed: true) }
        }
    }

    private func page(_ entry: PeekEntry, pushed: Bool) -> some View {
        PeekPage(entry: entry, content: model.peekContent(entry), canGoBack: pushed, actions: model.peekActions)
            .navigationBarBackButtonHidden()
    }
}

// MARK: - A page

/// One page of the peek: its title with Back and Close, then a ticket's or a pull request's page.
struct PeekPage: View {
    let entry: PeekEntry
    let content: PeekContent
    var canGoBack = false
    var actions = PeekActions()
    /// False in a snapshot, which `ImageRenderer` can't draw through a scroll view.
    var scrolls = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DesignTokens.Space.s2) {
                if canGoBack {
                    Button(action: actions.back) { Label(PeekNavigation.backTitle, systemImage: "chevron.left") }
                        .buttonStyle(PeekHeaderButtonStyle())
                        .help("Back (⌘[)")
                }
                Text(entry.title)
                    .font(DesignTokens.TypeStyle.section.font)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: DesignTokens.Space.s2)
                Button(action: actions.close) { Label(PeekNavigation.closeTitle, systemImage: "xmark") }
                    .buttonStyle(PeekHeaderButtonStyle())
                    .keyboardShortcut(.cancelAction)
                    .help("Close (Esc)")
            }
            .padding(.horizontal, DesignTokens.Space.s4)
            .padding(.vertical, DesignTokens.Space.s3)
            Divider()
            if scrolls {
                ScrollView { pageBody }
            } else {
                pageBody
            }
        }
        .frame(maxWidth: .infinity, maxHeight: scrolls ? .infinity : nil, alignment: .top)
        .background(DesignTokens.Surface.content.color)
        // Its chips push their own page; ⌘-click opens a ticket's page in the window.
        .environment(\.mentionReferences, content.references)
        .environment(\.openMention, OpenMentionAction(handler: actions.push))
        .environment(\.openMentionDirectly, OpenMentionAction(handler: actions.openDirectly))
    }

    private var pageBody: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s4) {
            switch content {
            case let .ticket(peek): TicketPeekBody(peek: peek, actions: actions)
            case let .other(popover): OtherPeekBody(popover: popover, openURL: actions.openURL)
            }
        }
        .padding(DesignTokens.Space.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The header's Back and Close: a symbol in a circle that lights under the pointer, drawn by SwiftUI so a snapshot
/// shows it.
private struct PeekHeaderButtonStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(.iconOnly)
            .font(DesignTokens.TypeStyle.body.font.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(width: 24, height: 24)
            .background(Circle().fill(Color.primary.opacity(configuration.isPressed ? 0.16 : hovering ? 0.08 : 0)))
            .contentShape(Circle())
            .onHover { hovering = $0 }
    }
}

/// A ticket's page: N2's head, then Now, Connected and the review brief's headline for a ticket Symphony tracks, or
/// the reference's facts for one it doesn't; then Open Ticket Page and Open in Linear.
private struct TicketPeekBody: View {
    let peek: TicketPeek
    let actions: PeekActions

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
            HStack(alignment: .center, spacing: DesignTokens.Space.s2) {
                Text([peek.head.identifier, peek.head.repoKey].compactMap { $0 }.joined(separator: " · "))
                    .font(DesignTokens.TypeStyle.label.font)
                    .foregroundStyle(.secondary)
                Spacer(minLength: DesignTokens.Space.s2)
                if let badge = peek.head.badge { StatusBadge(status: badge.status, word: badge.word).fixedSize() }
            }
            if let title = peek.head.title {
                Text(title)
                    .font(DesignTokens.TypeStyle.rowTitle.font)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let summary = peek.head.summary {
                ChipText(text: summary, font: DesignTokens.TypeStyle.callout.nsFont, color: .secondaryLabelColor)
            }
        }
        if !peek.head.facts.isEmpty {
            PeekFacts(facts: peek.head.facts.map { ($0.label, $0.value) })
        }
        if let now = peek.now {
            PeekSection(title: TicketPeek.nowTitle) {
                PeekFacts(facts: [("Stage", now.stage), ("Waiting", now.waitingOn), ("Work", now.pullRequest)].compactMap { label, value in
                    value.map { (label, $0) }
                })
            }
        }
        if let connected = peek.connected {
            PeekSection(title: TicketPeek.connectedTitle) {
                if let parent = connected.parent { ParentRow(parent: parent) }
                ForEach(connected.groups, id: \.label) { group in
                    VStack(alignment: .leading, spacing: DesignTokens.Space.s1) {
                        Text(group.label)
                            .font(DesignTokens.TypeStyle.callout.font)
                            .foregroundStyle(.secondary)
                        ForEach(group.rows, id: \.text) { row in
                            HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.s2) {
                                ChipText(text: row.text, font: DesignTokens.TypeStyle.callout.nsFont)
                                if let state = row.state {
                                    Text(state)
                                        .font(DesignTokens.TypeStyle.caption.font)
                                        .foregroundStyle(.secondary)
                                        .fixedSize()
                                }
                            }
                        }
                    }
                }
            }
        }
        if let headline = peek.headline {
            PeekSection(title: TicketPeek.headlineTitle) {
                ChipText(text: headline, font: DesignTokens.TypeStyle.callout.nsFont)
            }
        }
        Divider()
        HStack(spacing: DesignTokens.Space.s2) {
            Button(TicketPeek.openTicketPageTitle) { actions.openTicketPage(peek.identifier) }
                .buttonStyle(.borderedProminent)
                .help("Open \(peek.identifier)'s page; ⌘[ comes back here")
            if let url = peek.linearURL {
                Button(TicketPeek.openInLinearTitle) { actions.openURL(url) }
            }
        }
        .controlSize(.small)
    }
}

/// N10 in the peek: the parent's chip, then a segment per sub-ticket in landing order, filled as each one goes.
private struct ParentRow: View {
    let parent: TicketPeek.Parent

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s1) {
            Text("Part of")
                .font(DesignTokens.TypeStyle.callout.font)
                .foregroundStyle(.secondary)
            ChipText(text: parent.text, font: DesignTokens.TypeStyle.callout.nsFont)
            if let progress = parent.progress {
                HStack(spacing: DesignTokens.Space.s2) {
                    if !parent.children.isEmpty {
                        HStack(spacing: 2) {
                            ForEach(Array(parent.children.enumerated()), id: \.offset) { _, status in
                                Capsule()
                                    .fill(status == .idle ? Color.secondary.opacity(0.25) : status.tint)
                                    .frame(height: 4)
                            }
                        }
                        .frame(maxWidth: 160)
                        .accessibilityHidden(true)
                    }
                    Text(progress)
                        .font(DesignTokens.TypeStyle.caption.font)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// A pull request's page (N3's head and figures) with Open on GitHub, or the line for a mention Symphony can't see
/// with its link.
private struct OtherPeekBody: View {
    let popover: ReferencePopover
    let openURL: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s3) {
            switch popover.content {
            case let .pullRequest(pullRequest): PullRequestPopover(pullRequest: pullRequest)
            case let .ticket(ticket): TicketPopover(ticket: ticket)
            case let .missing(line):
                Label(line, systemImage: "eye.slash")
                    .font(DesignTokens.TypeStyle.body.font)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        if let link = popover.link {
            Divider()
            Button(link.title) { openURL(link.url) }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
    }
}

/// A titled part of a peek page.
private struct PeekSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
            Text(title)
                .font(DesignTokens.TypeStyle.rowTitle.font)
                .accessibilityAddTraits(.isHeader)
            content
        }
    }
}

/// Labelled lines whose values are chip text.
private struct PeekFacts: View {
    let facts: [(label: String, value: String)]

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s1) {
            ForEach(facts, id: \.label) { fact in
                HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.s3) {
                    Text(fact.label)
                        .font(DesignTokens.TypeStyle.callout.font)
                        .foregroundStyle(.secondary)
                        .frame(width: 72, alignment: .leading)
                    ChipText(text: fact.value, font: DesignTokens.TypeStyle.callout.nsFont)
                }
            }
        }
    }
}
