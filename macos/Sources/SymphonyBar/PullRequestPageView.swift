import SwiftUI
import SymphonyBarCore

// MARK: - The window model's pull request page (D15)

extension SymphonyWindowModel {
    /// The pull request whose page the window shows, nil elsewhere.
    var shownPullRequest: PullRequestPlace? {
        if case let .pullRequest(place) = history.current { return place }
        return nil
    }

    /// The page shown, from what its endpoint answered (nil while it reads) and the mentions the Inbox resolved.
    var pullRequestScreen: PullRequestScreen? {
        guard let place = shownPullRequest else { return nil }
        let references = (inbox?.items ?? []).reduce(into: [String: Reference]()) { all, item in
            all.merge(item.references) { kept, _ in kept }
        }
        return PullRequestScreen(place, result: pullRequestResult, url: pullRequestLinks[place], references: references, now: Date())
    }

    /// Opens pull request `place`'s page (D15), pushed like a ticket's page: ⌘[ returns to where it opened. `url` is the
    /// link it was opened from, for Open on GitHub until Symphony answers.
    func openPullRequest(_ place: PullRequestPlace, url: URL?) {
        if let url { pullRequestLinks[place] = url }
        guard shownPullRequest != place else { return }
        history.visit(.pullRequest(place))
        showPlace()
    }

    /// Reads the shown page's endpoint: when it opens, on Refresh and on Try Again, keeping what it shows until Symphony
    /// answers. Symphony keeps a page GitHub answered for one poll interval, so a read costs GitHub nothing more.
    func readPullRequest() {
        guard let place = shownPullRequest, !readingPullRequest, state.countsKnown else { return }
        readingPullRequest = true
        Task {
            let result = await client.pullRequestPage(repoKey: place.repoKey, number: place.number)
            readingPullRequest = false
            // A page left while its read was out doesn't take it; the page opened meanwhile reads now.
            guard shownPullRequest == place else {
                if pullRequestResult == nil { readPullRequest() }
                return
            }
            pullRequestResult = result
        }
    }

    /// Open Ticket: the page of the ticket the pull request belongs to.
    func openPullRequestTicket() {
        guard let ticket = pullRequestScreen?.ticket else { return }
        openTicket(ticket)
    }

    /// ⌘-click or ⌘Return on a chip, past the peek: a ticket's page (D3), a pull request's page (D15), or its link.
    func openDirectly(_ mention: Mention) {
        switch MentionTarget(mention) {
        case let .ticketPage(identifier)?: openTicket(identifier)
        case let .pullRequestPage(place, url)?: openPullRequest(place, url: url)
        case let .link(url)?: onOpenURL(url)
        case nil: break
        }
    }
}

// MARK: - D15: the page

/// What the page's buttons and chips do.
struct PullRequestPageActions {
    var openURL: (URL) -> Void = { _ in }
    var tryAgain: () -> Void = {}
    /// A click on a chip: the ticket's or the other pull request's page.
    var openMention: (Mention) -> Void = { _ in }
}

/// D15 for the window: the page, or C20 while Symphony can't serve it.
struct PullRequestPageContent: View {
    @ObservedObject var model: SymphonyWindowModel

    var body: some View {
        if let screen = model.pullRequestScreen {
            PullRequestPageView(
                screen: screen,
                actions: PullRequestPageActions(openURL: model.onOpenURL, tryAgain: model.readPullRequest, openMention: model.openDirectly)
            )
        }
    }
}

/// The page in a scroll view, laid out for the width it gets; its states that hold no page are C20.
struct PullRequestPageView: View {
    let screen: PullRequestScreen
    let actions: PullRequestPageActions
    @State private var width: CGFloat = DesignTokens.Layout.windowWidth - DesignTokens.Layout.sidebarWidth

    var body: some View {
        switch screen.content {
        case .loading, .page:
            ScrollView {
                PullRequestPageBody(screen: screen, actions: actions, width: width)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        default:
            PullRequestPageBody(screen: screen, actions: actions, width: width)
        }
    }
}

/// The page's cards, outside the scroll view so they also render offscreen: What it does, Review history and What it
/// changes on the left; Health, Size and Ticket on the right, below the left column when the window is narrow.
struct PullRequestPageBody: View {
    let screen: PullRequestScreen
    let actions: PullRequestPageActions
    let width: CGFloat

    /// Wider than the ticket page's, so Health's values fit on one line.
    static let sideColumnWidth: CGFloat = 330

    private var sideBySide: Bool {
        width - 2 * DesignTokens.Space.s5 >= TicketPageBody.mainColumnMinWidth + DesignTokens.Space.s4 + Self.sideColumnWidth
    }

    var body: some View {
        switch screen.content {
        case .loading, .page:
            pageBody
        default:
            emptyState.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private var pageBody: some View {
        switch screen.content {
        case .loading:
            columns(page: nil)
        case let .page(page):
            columns(page: page)
                // The mentions in the page's text are chips (N1); a click opens what they name.
                .environment(\.mentionReferences, page.references)
                .environment(\.openMention, OpenMentionAction(handler: actions.openMention))
                .environment(\.openMentionDirectly, OpenMentionAction(handler: actions.openMention))
        default:
            EmptyView()
        }
    }

    /// C20 for the states that hold no page.
    @ViewBuilder private var emptyState: some View {
        switch screen.content {
        case .loading, .page:
            EmptyView()
        case let .untracked(line):
            EmptyState(title: line, symbol: PullRequestScreen.symbol, actions: gitHubAction)
        case let .notFound(line):
            EmptyState(title: line, symbol: "questionmark.circle", actions: gitHubAction)
        case .unsupported:
            EmptyState(title: EndpointPlaceholder.updateSymphony, symbol: EndpointPlaceholder.updateSymbol)
        case let .failed(line):
            EmptyState(title: line, symbol: DesignTokens.Status.problem.symbol, actions: [(PullRequestScreen.tryAgainTitle, actions.tryAgain)])
        }
    }

    private var gitHubAction: [(title: String, perform: () -> Void)] {
        guard let url = screen.gitHubURL else { return [] }
        return [(PullRequestScreen.openOnGitHubTitle, { actions.openURL(url) })]
    }

    private func columns(page: PullRequestScreen.Page?) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s5) {
            PullRequestHeader(screen: screen, page: page)
            let layout = sideBySide
                ? AnyLayout(HStackLayout(alignment: .top, spacing: DesignTokens.Space.s4))
                : AnyLayout(VStackLayout(alignment: .leading, spacing: DesignTokens.Space.s4))
            layout {
                VStack(alignment: .leading, spacing: DesignTokens.Space.s4) {
                    Card(title: PullRequestScreen.whatItDoesTitle) {
                        if let page {
                            if let summary = page.summary {
                                ChipText(text: summary)
                            } else {
                                GitHubUnavailable(tryAgain: actions.tryAgain)
                            }
                        } else {
                            Placeholder(lines: 3)
                        }
                    }
                    Card(title: PullRequestScreen.reviewHistoryTitle) {
                        if let page {
                            ReviewHistory(rows: page.history)
                        } else {
                            Placeholder(lines: 2)
                        }
                    }
                    Card(title: PullRequestScreen.whatItChangesTitle) {
                        if let page {
                            if let areas = page.areas {
                                ChangeAreas(areas: areas)
                            } else {
                                GitHubUnavailable(tryAgain: actions.tryAgain)
                            }
                        } else {
                            Placeholder(lines: 4)
                        }
                    }
                }
                .frame(minWidth: sideBySide ? TicketPageBody.mainColumnMinWidth : nil, maxWidth: .infinity, alignment: .topLeading)
                VStack(alignment: .leading, spacing: DesignTokens.Space.s4) {
                    Card(title: PullRequestScreen.healthTitle) {
                        if let page {
                            HealthGrid(facts: page.health, gitHubAvailable: page.gitHubAvailable, tryAgain: actions.tryAgain)
                        } else {
                            Placeholder(lines: 4)
                        }
                    }
                    Card(title: PullRequestScreen.sizeTitle) {
                        if let page {
                            if let size = page.size {
                                SizeFigures(stats: size)
                            } else {
                                GitHubUnavailable(tryAgain: actions.tryAgain)
                            }
                        } else {
                            Placeholder(lines: 1)
                        }
                    }
                    Card(title: PullRequestScreen.ticketTitle) {
                        if let page {
                            TicketFacts(ticket: page.ticket)
                        } else {
                            Placeholder(lines: 2)
                        }
                    }
                }
                .frame(maxWidth: sideBySide ? Self.sideColumnWidth : .infinity, alignment: .topLeading)
            }
        }
        .padding(DesignTokens.Space.s5)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

/// The title as a sentence, with the state's badge and its dates.
private struct PullRequestHeader: View {
    let screen: PullRequestScreen
    let page: PullRequestScreen.Page?

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
            if let page, page.badge != nil || page.dates != nil {
                HStack(spacing: DesignTokens.Space.s2) {
                    if let badge = page.badge { StatusBadge(status: badge.status, word: badge.word).fixedSize() }
                    if let dates = page.dates {
                        Text(dates)
                            .font(DesignTokens.TypeStyle.callout.font)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Text(screen.title)
                .font(DesignTokens.TypeStyle.sentence.font)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
        }
    }
}

/// A card's body while it reads: grey bars where its lines will be.
private struct Placeholder: View {
    let lines: Int

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
            ForEach(0..<lines, id: \.self) { line in
                Text(String(repeating: "x", count: line == lines - 1 ? 28 : 52))
                    .font(DesignTokens.TypeStyle.body.font)
            }
        }
        .redacted(reason: .placeholder)
        .accessibilityHidden(true)
    }
}

/// What a card that needs GitHub says when Symphony couldn't read it, with Try Again.
private struct GitHubUnavailable: View {
    let tryAgain: () -> Void

    var body: some View {
        HStack(spacing: DesignTokens.Space.s2) {
            Label(PullRequestScreen.gitHubUnavailable, systemImage: "icloud.slash")
                .font(DesignTokens.TypeStyle.body.font)
                .foregroundStyle(.secondary)
            Spacer(minLength: DesignTokens.Space.s2)
            Button(PullRequestScreen.tryAgainTitle, action: tryAgain)
                .controlSize(.small)
        }
    }
}

/// Each verdict, oldest first: when, its badge in words, what judged it, and the reason with its mentions as chips.
private struct ReviewHistory: View {
    let rows: [PullRequestScreen.HistoryRow]

    var body: some View {
        if rows.isEmpty {
            Text(PullRequestScreen.noHistory)
                .font(DesignTokens.TypeStyle.body.font)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: DesignTokens.Space.s3) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    VStack(alignment: .leading, spacing: DesignTokens.Space.s1) {
                        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.s2) {
                            if let time = row.timeText {
                                Text(time)
                                    .font(DesignTokens.TypeStyle.callout.font)
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                                    // The badges line up whether the time has its date or not.
                                    .frame(minWidth: 84, alignment: .leading)
                            }
                            StatusBadge(status: row.badge.status, word: row.badge.word).fixedSize()
                            Text(row.title).font(DesignTokens.TypeStyle.rowTitle.font)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(row.accessibilityLabel)
                        if let reason = row.reason {
                            ChipText(text: reason, font: DesignTokens.TypeStyle.callout.nsFont, color: .secondaryLabelColor)
                        }
                    }
                }
            }
        }
    }
}

/// The areas it changes, each with its files and lines, and the line that says the diff is on GitHub.
private struct ChangeAreas: View {
    let areas: [PullRequestScreen.AreaRow]

    var body: some View {
        if areas.isEmpty {
            Text(PullRequestScreen.noAreas)
                .font(DesignTokens.TypeStyle.body.font)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: DesignTokens.Space.s3) {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: DesignTokens.Space.s4, verticalSpacing: DesignTokens.Space.s2) {
                    ForEach(areas, id: \.name) { area in
                        GridRow {
                            Text(area.name).font(DesignTokens.TypeStyle.body.font)
                            Text(area.files)
                                .font(DesignTokens.TypeStyle.callout.font)
                                .foregroundStyle(.secondary)
                                .gridColumnAlignment(.trailing)
                            Text(area.additions)
                                .foregroundStyle(DesignTokens.Status.done.tint)
                                .gridColumnAlignment(.trailing)
                            Text(area.deletions)
                                .foregroundStyle(DesignTokens.Status.problem.tint)
                                .gridColumnAlignment(.trailing)
                        }
                        .font(DesignTokens.TypeStyle.callout.font)
                        .monospacedDigit()
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(area.accessibilityLabel)
                    }
                }
                Text(PullRequestScreen.areasFootnote)
                    .font(DesignTokens.TypeStyle.caption.font)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Checks, Code Review, QA and the pull requests it overlaps, as chips.
private struct HealthGrid: View {
    let facts: [PullRequestScreen.Fact]
    let gitHubAvailable: Bool
    let tryAgain: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s3) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: DesignTokens.Space.s3, verticalSpacing: DesignTokens.Space.s2) {
                ForEach(facts, id: \.label) { fact in
                    GridRow {
                        Text(fact.label)
                            .font(DesignTokens.TypeStyle.callout.font)
                            .foregroundStyle(.secondary)
                            .gridColumnAlignment(.leading)
                        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.s1) {
                            if let status = fact.status {
                                Image(systemName: status.symbol)
                                    .foregroundStyle(status.tint)
                                    .accessibilityHidden(true)
                            }
                            ChipText(text: fact.value, font: DesignTokens.TypeStyle.callout.nsFont)
                        }
                    }
                }
            }
            if !gitHubAvailable {
                Button(PullRequestScreen.tryAgainTitle, action: tryAgain)
                    .controlSize(.small)
            }
        }
    }
}

/// Files, lines and commits.
private struct SizeFigures: View {
    let stats: [PullRequestScreen.Stat]

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.s4) {
            ForEach(stats, id: \.label) { stat in
                VStack(alignment: .leading, spacing: 0) {
                    Text(stat.value)
                        .font(DesignTokens.TypeStyle.rowTitle.font)
                        .monospacedDigit()
                    Text(stat.label)
                        .font(DesignTokens.TypeStyle.caption.font)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(stat.accessibilityLabel)
            }
        }
    }
}

/// The ticket as a chip, its stage and what it waits on.
private struct TicketFacts: View {
    let ticket: PullRequestScreen.TicketCard

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
            ChipText(text: ticket.text)
            HStack(spacing: DesignTokens.Space.s2) {
                if let stage = ticket.stage { StatusBadge(status: stage.status, word: stage.word).fixedSize() }
                if let waitingOn = ticket.waitingOn {
                    Text(waitingOn)
                        .font(DesignTokens.TypeStyle.callout.font)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
