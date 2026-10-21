import Foundation

/// Where a pull request page is: its repo and number, as `WindowPlace.pullRequest` names it.
public struct PullRequestPlace: Hashable {
    public var repoKey: String
    public var number: Int

    public init(repoKey: String, number: Int) {
        self.repoKey = repoKey
        self.number = number
    }

    /// The page of a pull request reference, nil when it names no repo.
    public init?(_ reference: Reference) {
        guard case let .pullRequest(pullRequest) = reference, let repoKey = pullRequest.repoKey else { return nil }
        self.init(repoKey: repoKey, number: pullRequest.number)
    }

    /// The page of a pull request link of repo `repoKey`: ".../pull/448".
    public init?(repoKey: String?, url: URL) {
        let parts = url.pathComponents.filter { $0 != "/" }
        guard let repoKey, let index = parts.firstIndex(of: "pull"), index + 1 < parts.count, let number = Int(parts[index + 1]) else {
            return nil
        }
        self.init(repoKey: repoKey, number: number)
    }
}

/// What ⌘-click or ⌘Return on a chip opens (N1), past the peek: a ticket's page (D3), a pull request's page (D15), or
/// the link of a mention Symphony can't open a page for.
public enum MentionTarget: Equatable {
    case ticketPage(String)
    case pullRequestPage(PullRequestPlace, url: URL?)
    case link(URL)

    public init?(_ mention: Mention) {
        switch mention.reference {
        case .ticket where mention.kind == .ticket:
            self = .ticketPage(mention.key)
        case let .pullRequest(pullRequest):
            if let place = PullRequestPlace(mention.reference) {
                self = .pullRequestPage(place, url: pullRequest.url)
            } else if let url = pullRequest.url {
                self = .link(url)
            } else {
                return nil
            }
        default:
            guard let url = mention.reference.url else { return nil }
            self = .link(url)
        }
    }
}

/// D15: the pull request page as the window draws it, from what `GET /api/v1/pull_requests/:repo_key/:number` answered
/// (nil while it reads). Its story, the verdicts Symphony recorded, what it changes by area, its health, size and
/// ticket; never a file, a branch or a commit (the diff stays on GitHub). Pure, so every state is tested against the
/// `pull-request` fixture and its variants; the app draws it.
public struct PullRequestScreen: Equatable {
    public static let openOnGitHubTitle = "Open on GitHub"
    public static let openTicketTitle = "Open Ticket"
    /// The PR peek's button (N4) that opens this page.
    public static let openPageTitle = "Open Pull Request Page"
    public static let tryAgainTitle = "Try Again"
    /// What a card that needs GitHub says when Symphony couldn't read it.
    public static let gitHubUnavailable = "GitHub didn't answer."
    public static let whatItDoesTitle = "What it does"
    public static let reviewHistoryTitle = "Review history"
    public static let whatItChangesTitle = "What it changes"
    public static let healthTitle = "Health"
    public static let sizeTitle = "Size"
    public static let ticketTitle = "Ticket"
    public static let areasFootnote = "Grouped by area, not by file. Open on GitHub for the diff."
    public static let noSummary = "The pull request has no description."
    public static let noHistory = "No Code Review or QA verdict yet."
    public static let noAreas = "No changed files."
    public static let readingTitle = "Reading the pull request…"
    public static let symbol = ReferencePopover.pullRequestSymbol

    public typealias Badge = ReferencePopover.Badge
    public typealias Stat = ReferencePopover.Stat

    /// A verdict Symphony recorded, or the merge, in Review history: when, its badge in words, and the reason.
    public struct HistoryRow: Equatable {
        public var timeText: String?
        /// "Code Review", "QA", or "Pull request" for the merge.
        public var title: String
        public var badge: Badge
        public var reason: String?

        /// VoiceOver: "Oct 6, 11:40, Code Review, Changes asked. The old workflow's instructions…".
        public var accessibilityLabel: String {
            [timeText, title, badge.word].compactMap { $0 }.joined(separator: ", ") + (reason.map { ". \($0)" } ?? "")
        }
    }

    /// One area the pull request changes, with its files and lines.
    public struct AreaRow: Equatable {
        public var name: String
        /// "5 files".
        public var files: String
        /// "+18".
        public var additions: String
        /// "−240".
        public var deletions: String

        /// VoiceOver: "Agent instructions, 5 files, 18 lines added, 240 removed".
        public var accessibilityLabel: String
    }

    /// A line of Health: its label, its value as chip text, and a status symbol.
    public struct Fact: Equatable {
        public var label: String
        public var value: String
        public var status: DesignTokens.Status?
    }

    /// The Ticket card: the ticket as a chip, its stage and what it waits on.
    public struct TicketCard: Equatable {
        /// "TP-892 (Retire two old review steps)", whose identifier is a chip.
        public var text: String
        public var stage: Badge?
        /// "Waiting on you".
        public var waitingOn: String?
    }

    /// The loaded page: the left column's What it does, Review history and What it changes, the right column's Health,
    /// Size and Ticket. A card whose facts come from GitHub shows `gitHubUnavailable` with Try Again when Symphony
    /// couldn't read it; what Linear and Symphony know still shows.
    public struct Page: Equatable {
        /// The review state, or Merged or Closed.
        public var badge: Badge?
        /// "Opened 2 days ago · last push 5 h ago", "Merged 2 h ago", "Closed 3 days ago".
        public var dates: String?
        public var gitHubAvailable: Bool
        /// Nil while GitHub didn't answer.
        public var summary: String?
        /// Oldest first; a merged pull request's ends with Merged.
        public var history: [HistoryRow]
        /// Nil while GitHub didn't answer.
        public var areas: [AreaRow]?
        /// Checks, Code Review, QA and Overlaps.
        public var health: [Fact]
        /// Nil while GitHub didn't answer.
        public var size: [Stat]?
        public var ticket: TicketCard
        /// The tickets and pull requests the page's text names, for its chips (N1).
        public var references: [String: Reference]
    }

    public enum Content: Equatable {
        /// Placeholder cards, with the spinner in the subtitle.
        case loading
        case page(Page)
        /// A pull request no ticket Symphony sees owns: its title and Open on GitHub only.
        case untracked(String)
        /// C20: GitHub doesn't have it, or Symphony doesn't know the repo; Open on GitHub when the link is known.
        case notFound(String)
        /// The Symphony running predates the page.
        case unsupported
        /// Symphony didn't answer: C20 with Try Again.
        case failed(String)
    }

    public var place: PullRequestPlace
    /// The toolbar's title: "#448 · Remove the Final verification and Supervisor check flows".
    public var title: String
    /// The toolbar's line under it: "symphony · for TP-892", "symphony · for TP-892 · merged 2 h ago".
    public var subtitle: String
    /// True while it reads: the spinner beside the subtitle.
    public var isLoading: Bool
    /// Open on GitHub's link.
    public var gitHubURL: URL?
    /// Open Ticket's ticket.
    public var ticket: String?
    public var content: Content

    /// `result` is nil while the page reads; `url` is the link the page was opened from, for Open on GitHub before
    /// Symphony answers or when it can't find it. `references` are the window's (the Inbox's), richer than what the
    /// page itself knows of the tickets and pull requests it names.
    public init(
        _ place: PullRequestPlace, result: PullRequestPageResult?, url: URL? = nil, references: [String: Reference] = [:],
        now: Date, timeZone: TimeZone = .current
    ) {
        self.place = place
        let page: PullRequestPage? = if case let .loaded(page)? = result { page } else { nil }
        let name = page?.title.map { Self.title($0) }.flatMap { $0.isEmpty ? nil : $0 }
        title = (["#\(place.number)"] + [name].compactMap { $0 }).joined(separator: " · ")
        gitHubURL = page?.url ?? url
        ticket = page?.ticket?.identifier
        isLoading = result == nil

        var subtitle = [place.repoKey] + [ticket.map { "for \($0)" }].compactMap { $0 }
        switch page?.state {
        case .merged?: subtitle.append(page?.mergedAt.map { "merged \(Self.ago($0, now: now))" } ?? "merged")
        case .closed?: subtitle.append("closed")
        default: break
        }
        self.subtitle = subtitle.joined(separator: " · ")

        switch result {
        case nil:
            content = .loading
        case let .loaded(page)?:
            if page.ticket == nil {
                content = .untracked("Symphony doesn't track #\(place.number): no ticket it sees owns it.")
            } else {
                content = .page(Self.page(page, place: place, references: references, now: now, timeZone: timeZone))
            }
        case .notFound?:
            content = .notFound("Symphony can't find #\(place.number) in \(place.repoKey).")
        case .unsupported?:
            content = .unsupported
        case let .failed(message)?:
            content = .failed(message)
        }
    }

    /// Every string the page shows, in reading order: the toolbar's, then each card's.
    public var renderedStrings: [String] {
        var strings = [title, subtitle]
        switch content {
        case .loading:
            strings.append(Self.readingTitle)
        case let .page(page):
            strings += [page.badge?.word, page.dates].compactMap { $0 }
            strings += [Self.whatItDoesTitle, page.summary ?? Self.gitHubUnavailable]
            strings.append(Self.reviewHistoryTitle)
            strings += page.history.isEmpty ? [Self.noHistory] : page.history.flatMap { [$0.timeText, $0.title, $0.badge.word, $0.reason].compactMap { $0 } }
            strings.append(Self.whatItChangesTitle)
            if let areas = page.areas {
                strings += areas.isEmpty ? [Self.noAreas] : areas.flatMap { [$0.name, $0.files, $0.additions, $0.deletions] } + [Self.areasFootnote]
            } else {
                strings.append(Self.gitHubUnavailable)
            }
            strings.append(Self.healthTitle)
            strings += page.health.flatMap { [$0.label, $0.value] }
            strings.append(Self.sizeTitle)
            strings += page.size?.map(\.accessibilityLabel) ?? [Self.gitHubUnavailable]
            strings += [Self.ticketTitle, page.ticket.text] + [page.ticket.stage?.word, page.ticket.waitingOn].compactMap { $0 }
        case let .untracked(line), let .notFound(line), let .failed(line):
            strings.append(line)
        case .unsupported:
            strings.append(EndpointPlaceholder.updateSymphony)
        }
        return strings
    }

    /// The title without the ticket identifier it starts with: the subtitle says which ticket it is for.
    static func title(_ title: String) -> String {
        let leading = try! NSRegularExpression(pattern: #"^\s*\[?[A-Z][A-Z0-9]*-\d+\]?[\s:–—-]*"#)
        let range = NSRange(location: 0, length: (title as NSString).length)
        return leading.stringByReplacingMatches(in: title, range: range, withTemplate: "").trimmingWhitespace()
    }

    private static func page(
        _ page: PullRequestPage, place: PullRequestPlace, references known: [String: Reference], now: Date, timeZone: TimeZone
    ) -> Page {
        let clock = { (date: Date) in StatusMenu.clockTime(date, now: now, timeZone: timeZone, dateFormat: "MMM d, HH:mm") }
        var references: [String: Reference] = [:]

        var history = page.reviewHistory.map { verdict in
            HistoryRow(
                timeText: verdict.at.map(clock),
                title: verdict.kind == .qa ? "QA" : "Code Review",
                badge: badge(verdict.verdict, kind: verdict.kind),
                reason: verdict.reason
            )
        }
        if page.state == .merged {
            history.append(HistoryRow(timeText: page.mergedAt.map(clock), title: "Pull request", badge: Badge(status: .done, word: "Merged")))
        }

        let areas = page.gitHubAvailable ? page.areas.map(area) : nil

        var health: [Fact] = []
        if !page.gitHubAvailable {
            health.append(Fact(label: "Checks", value: gitHubUnavailable))
        } else if let checks = page.health.checks, checks.passed + checks.failed + checks.pending > 0 {
            let counts = [(checks.failed, "failed"), (checks.pending, "running"), (checks.passed, "passed")]
                .filter { $0.0 > 0 }
                .map { "\($0.0) \($0.1)" }
            health.append(Fact(label: "Checks", value: counts.joined(separator: " · "), status: checks.state?.status))
        } else {
            health.append(Fact(label: "Checks", value: "None"))
        }
        if let review = page.health.codeReview {
            let verdict = badge(review.verdict, kind: .codeReview)
            health.append(Fact(label: "Code Review", value: "\(verdict.word) · round \(review.round)", status: verdict.status))
        } else {
            health.append(Fact(label: "Code Review", value: "Not reviewed yet"))
        }
        if let qa = page.health.qa {
            let verdict = badge(qa, kind: .qa)
            health.append(Fact(label: "QA", value: verdict.word, status: verdict.status))
        } else {
            health.append(Fact(label: "QA", value: "Not run yet"))
        }
        if page.health.overlaps.isEmpty {
            health.append(Fact(label: "Overlaps", value: "None"))
        } else {
            for overlap in page.health.overlaps {
                references["#\(overlap.number)"] = .pullRequest(Reference.PullRequest(
                    number: overlap.number, repoKey: place.repoKey, url: nil, title: nil, summary: nil, reviewState: .open,
                    reviewRounds: 0, files: nil, additions: nil, deletions: nil, checks: nil, ticket: overlap.ticket
                ))
                if let ticket = overlap.ticket { references[ticket] = .ticket(Reference.Ticket(identifier: ticket)) }
            }
            let value = page.health.overlaps.map { overlap in
                "#\(overlap.number)" + (overlap.ticket.map { " for \($0)" } ?? "")
            }
            health.append(Fact(label: "Overlaps", value: value.joined(separator: ", ")))
        }

        let size = page.size.map { size in
            [
                Stat(value: "\(size.files)", label: size.files == 1 ? "file" : "files"),
                Stat(value: "+\(size.additions) −\(size.deletions)", label: "lines"),
                Stat(value: "\(size.commits)", label: size.commits == 1 ? "commit" : "commits"),
            ]
        }

        // The page is only drawn for a pull request a ticket owns.
        let ticket = page.ticket ?? PullRequestPage.Ticket(identifier: "")
        references[ticket.identifier] = .ticket(Reference.Ticket(
            identifier: ticket.identifier, title: ticket.title, repoKey: place.repoKey, state: ticket.state, waitingOn: ticket.waitingOn
        ))
        // What the window knows of the same tickets and pull requests is richer: titles, links, figures.
        references.merge(known.filter { references[$0.key] != nil }) { _, known in known }

        return Page(
            badge: stateBadge(page),
            dates: dates(page, now: now),
            gitHubAvailable: page.gitHubAvailable,
            summary: page.gitHubAvailable ? page.summary.flatMap { $0.trimmingWhitespace().isEmpty ? nil : $0 } ?? noSummary : page.summary,
            history: history,
            areas: areas,
            health: health,
            size: size,
            ticket: TicketCard(
                text: ticket.identifier + (ticket.title.map { " (\($0))" } ?? ""),
                stage: ticket.state.map { Badge(status: ReferencePopover.status(state: $0, waitingOn: ticket.waitingOn), word: $0) },
                waitingOn: ticket.waitingOn.map { "Waiting on \($0)" }
            ),
            references: references
        )
    }

    private static func area(_ area: PullRequestPage.Area) -> AreaRow {
        AreaRow(
            name: area.name,
            files: area.files == 1 ? "1 file" : "\(area.files) files",
            additions: "+\(area.additions)",
            deletions: "−\(area.deletions)",
            accessibilityLabel: "\(area.name), \(area.files == 1 ? "1 file" : "\(area.files) files"), "
                + "\(area.additions) lines added, \(area.deletions) removed"
        )
    }

    /// A verdict in words: "Changes asked", "Approved", "Passed".
    static func badge(_ verdict: String, kind: PullRequestPage.Verdict.Kind) -> Badge {
        switch (kind, verdict) {
        case (.codeReview, "approve"): Badge(status: .done, word: "Approved")
        case (.codeReview, "request_changes"), (.codeReview, "rework"): Badge(status: .you, word: "Changes asked")
        case (_, "block"), (_, "blocked"): Badge(status: .problem, word: "Blocked")
        case (.qa, "pass"): Badge(status: .done, word: "Passed")
        case (.qa, "fail"): Badge(status: .problem, word: "Failed")
        case (.qa, "skip"): Badge(status: .idle, word: "Skipped")
        default: Badge(status: .idle, word: verdict.replacingOccurrences(of: "_", with: " ").capitalizingFirst)
        }
    }

    /// The header's badge: Merged or Closed, else the review state.
    private static func stateBadge(_ page: PullRequestPage) -> Badge? {
        let state: Reference.PullRequest.ReviewState? = switch page.state {
        case .merged?: .merged
        case .closed?: .closed
        case .open?: page.reviewState
        case nil: page.gitHubAvailable ? nil : page.reviewState
        }
        return state.map { Badge(status: $0.status, word: $0.word) }
    }

    private static func dates(_ page: PullRequestPage, now: Date) -> String? {
        switch page.state {
        case .merged?:
            return page.mergedAt.map { "Merged \(ago($0, now: now))" } ?? "Merged"
        case .closed?:
            return "Closed without merging"
        default:
            let parts = [page.openedAt.map { "Opened \(ago($0, now: now))" }, page.lastPushedAt.map { "last push \(ago($0, now: now))" }]
            let line = parts.compactMap { $0 }.joined(separator: " · ")
            return line.isEmpty ? nil : line
        }
    }

    /// "2 h ago", "just now".
    static func ago(_ date: Date, now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        return seconds < 60 ? "just now" : "\(Overview.duration(seconds)) ago"
    }
}

private extension String {
    var capitalizingFirst: String { prefix(1).uppercased() + dropFirst() }
}
