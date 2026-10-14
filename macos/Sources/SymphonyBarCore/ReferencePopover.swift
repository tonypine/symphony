import Foundation

/// What a chip's popover shows (N2 for a ticket, N3 for a pull request), or the line for a mention Symphony can't
/// see. Pure, so each part is tested against the fixtures; the app draws it.
public struct ReferencePopover: Equatable {
    /// A C7 badge: a status's symbol and color with its word.
    public struct Badge: Equatable {
        public var status: DesignTokens.Status
        public var word: String
    }

    /// A labelled line: "Part of", "TP-880 · Remove the Supervisor check".
    public struct Fact: Equatable {
        public var label: String
        public var value: String
    }

    /// One of a pull request's figures: its value, what it counts, and a status symbol for the checks.
    public struct Stat: Equatable {
        public var value: String
        public var label: String
        public var status: DesignTokens.Status?

        /// VoiceOver: "2 review rounds".
        public var accessibilityLabel: String { [value, label].filter { !$0.isEmpty }.joined(separator: " ") }
    }

    public struct Link: Equatable {
        public var title: String
        public var url: URL
    }

    /// N2: identifier · repo with the stage badge, the title, the summary, then the facts.
    public struct Ticket: Equatable {
        public var identifier: String
        public var repoKey: String?
        public var badge: Badge?
        public var title: String?
        public var summary: String?
        public var facts: [Fact]
    }

    /// N3: the number and its ticket with the review state, the title, the summary, then the stats.
    public struct PullRequest: Equatable {
        public var number: String
        /// "for TP-892".
        public var forTicket: String?
        public var state: Badge
        public var title: String?
        public var summary: String?
        public var stats: [Stat]
    }

    public enum Content: Equatable {
        case ticket(Ticket)
        case pullRequest(PullRequest)
        /// "Symphony can't see TP-999."
        case missing(String)
    }

    /// The popover's width (N2, N3).
    public static let width: Double = 330
    public static let pullRequestSymbol = "arrow.triangle.pull"

    public var content: Content
    /// The footer's quiet line: what a click on the chip does.
    public var hint: String?
    /// The footer's button: Open in Linear, Open on GitHub.
    public var link: Link?

    public init(_ mention: Mention) {
        switch mention.reference {
        case let .ticket(ticket):
            var facts: [Fact] = []
            if let parent = ticket.parent {
                facts.append(Fact(label: "Part of", value: [parent.identifier, parent.title].compactMap { $0 }.joined(separator: " · ")))
            }
            if let pullRequest = ticket.pullRequest {
                facts.append(Fact(label: "Work", value: (["PR #\(pullRequest.number)"] + [pullRequest.checks.map(\.words)].compactMap { $0 }).joined(separator: " · ")))
            }
            if let waitingOn = ticket.waitingOn { facts.append(Fact(label: "Waiting on", value: waitingOn)) }
            content = .ticket(Ticket(
                identifier: ticket.identifier, repoKey: ticket.repoKey,
                badge: ticket.state.map { Badge(status: Self.status(state: $0, waitingOn: ticket.waitingOn), word: $0) },
                title: ticket.title, summary: ticket.summary, facts: facts
            ))
            hint = "Click to open the ticket page"
            link = ticket.url.map { Link(title: "Open in Linear", url: $0) }
        case let .pullRequest(pullRequest):
            var stats = [Stat(value: "\(pullRequest.reviewRounds)", label: pullRequest.reviewRounds == 1 ? "review round" : "review rounds")]
            if let files = pullRequest.files { stats.append(Stat(value: "\(files)", label: files == 1 ? "file" : "files")) }
            if let additions = pullRequest.additions, let deletions = pullRequest.deletions {
                stats.append(Stat(value: "+\(additions) −\(deletions)", label: "lines"))
            }
            if let checks = pullRequest.checks { stats.append(Stat(value: "", label: checks.words.capitalizedFirst, status: checks.status)) }
            content = .pullRequest(PullRequest(
                number: "#\(pullRequest.number)", forTicket: pullRequest.ticket.map { "for \($0)" },
                state: Badge(status: pullRequest.reviewState.status, word: pullRequest.reviewState.word),
                title: pullRequest.title, summary: pullRequest.summary, stats: stats
            ))
            hint = "Click to open it on GitHub"
            link = pullRequest.url.map { Link(title: "Open on GitHub", url: $0) }
        case let .missing(url):
            content = .missing("Symphony can't see \(mention.key).")
            hint = nil
            link = url.map { Link(title: mention.kind == .pullRequest ? "Open on GitHub" : "Open in Linear", url: $0) }
        }
    }

    /// A ticket's stage as a C7 status: waiting on the Director, working, done or idle.
    static func status(state: String, waitingOn: String?) -> DesignTokens.Status {
        switch state.lowercased() {
        case "done": .done
        case "canceled", "cancelled", "duplicate", "backlog", "todo", "triage": .idle
        case "plan review": .you
        default: waitingOn == "you" ? .you : .working
        }
    }
}

extension Reference.Checks {
    /// "checks passed", "checks failed", "checks running".
    public var words: String {
        switch self {
        case .passed: "checks passed"
        case .failed: "checks failed"
        case .pending: "checks running"
        }
    }

    public var status: DesignTokens.Status {
        switch self {
        case .passed: .done
        case .failed: .problem
        case .pending: .working
        }
    }
}

extension Reference.PullRequest.ReviewState {
    public var status: DesignTokens.Status {
        switch self {
        case .open: .working
        case .changesRequested: .you
        case .approved, .merged: .done
        case .closed: .idle
        }
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
