import Foundation

/// A ticket or pull request an Inbox item mentions, as Symphony resolved it on its poll (`references`, keyed by the
/// mention exactly as the item's text writes it: "TP-891", "PR #448", "#448"). What Symphony couldn't read — another
/// workspace, a deleted ticket, GitHub down — and a kind this app doesn't know come back as `missing`.
public enum Reference: Hashable {
    case ticket(Ticket)
    case pullRequest(PullRequest)
    /// Unreadable: the link is Symphony's best guess, nil when it has none.
    case missing(url: URL?)

    /// The outcome of a pull request's checks.
    public enum Checks: String, Hashable {
        case passed
        case failed
        case pending
    }

    public struct Ticket: Hashable {
        public struct Parent: Hashable {
            public var identifier: String
            public var title: String?
        }

        /// The ticket's newest pull request.
        public struct PullRequest: Hashable {
            public var number: Int
            public var url: URL?
            public var checks: Checks?
        }

        public var identifier: String
        public var title: String?
        public var repoKey: String?
        public var state: String?
        /// Its Symphony status line, else its description's first sentence: plain text, at most 160 characters.
        public var summary: String?
        public var url: URL?
        public var parent: Parent?
        public var pullRequest: PullRequest?
        /// What it waits on, in the ticket page's words ("you", "a blocker: TP-1", "CI"); nil while it runs or once done.
        public var waitingOn: String?
    }

    public struct PullRequest: Hashable {
        public enum ReviewState: String, Hashable {
            case open
            case changesRequested = "changes_requested"
            case approved
            case merged
            case closed
        }

        public var number: Int
        public var repoKey: String?
        public var url: URL?
        public var title: String?
        /// The first sentence of its `## This PR` section, else of its body.
        public var summary: String?
        public var reviewState: ReviewState
        /// How many times Symphony's Code Review judged it.
        public var reviewRounds: Int
        public var files: Int?
        public var additions: Int?
        public var deletions: Int?
        public var checks: Checks?
        /// The ticket it belongs to.
        public var ticket: String?
    }

    /// The link a mention opens.
    public var url: URL? {
        switch self {
        case let .ticket(ticket): ticket.url
        case let .pullRequest(pullRequest): pullRequest.url
        case let .missing(url): url
        }
    }

    struct Payload: Decodable {
        struct ParentPayload: Decodable {
            let identifier: String?
            let title: String?
        }

        struct AttachedPayload: Decodable {
            let number: Int?
            let url: String?
            let checks: String?
        }

        let kind: String?
        let url: String?
        let identifier: String?
        let title: String?
        let repoKey: String?
        let state: String?
        let summary: String?
        let parent: ParentPayload?
        let pullRequest: AttachedPayload?
        let waitingOn: String?
        let number: Int?
        let reviewState: String?
        let reviewRounds: Int?
        let files: Int?
        let additions: Int?
        let deletions: Int?
        let checks: String?
        let ticket: String?
    }

    init(_ payload: Payload) {
        let url = payload.url.flatMap(URL.init(string:))
        switch payload.kind {
        case "ticket" where payload.identifier != nil:
            self = .ticket(Ticket(
                identifier: payload.identifier ?? "",
                title: payload.title,
                repoKey: payload.repoKey,
                state: payload.state,
                summary: payload.summary,
                url: url,
                parent: payload.parent.flatMap { parent in
                    parent.identifier.map { Ticket.Parent(identifier: $0, title: parent.title) }
                },
                pullRequest: payload.pullRequest.flatMap { attached in
                    attached.number.map {
                        Ticket.PullRequest(
                            number: $0,
                            url: attached.url.flatMap(URL.init(string:)),
                            checks: attached.checks.flatMap(Checks.init(rawValue:))
                        )
                    }
                },
                waitingOn: payload.waitingOn
            ))
        case "pull_request" where payload.number != nil:
            self = .pullRequest(PullRequest(
                number: payload.number ?? 0,
                repoKey: payload.repoKey,
                url: url,
                title: payload.title,
                summary: payload.summary,
                reviewState: payload.reviewState.flatMap(PullRequest.ReviewState.init(rawValue:)) ?? .open,
                reviewRounds: payload.reviewRounds ?? 0,
                files: payload.files,
                additions: payload.additions,
                deletions: payload.deletions,
                checks: payload.checks.flatMap(Checks.init(rawValue:)),
                ticket: payload.ticket
            ))
        default:
            self = .missing(url: url)
        }
    }
}

/// Where an Inbox item's ticket sits (`context`): its parent's progress, its pull request, the tickets connected to
/// it and the decisions already made on it.
public struct TicketContext: Equatable {
    public struct Parent: Equatable {
        public var identifier: String
        public var title: String?
        public var done: Int
        public var total: Int
        /// Each sub-ticket's Linear state type ("completed", "started", "unstarted", "backlog", "triage"), in landing
        /// order.
        public var children: [String]
    }

    public struct PullRequest: Equatable {
        public var number: Int
        public var url: URL?
        public var checks: Reference.Checks?
        /// How many times Code Review sent it back.
        public var sentBack: Int
    }

    public struct Connected: Equatable {
        public var identifier: String
        public var title: String?
        public var state: String?
    }

    public struct EarlierDecision: Equatable {
        public var at: Date?
        public var title: String?
        public var answer: String?
    }

    public var parent: Parent?
    public var pullRequest: PullRequest?
    public var blockedBy: [Connected]
    public var blocks: [Connected]
    public var related: [Connected]
    /// Requests on this ticket a person answered, newest first, at most three.
    public var earlierDecisions: [EarlierDecision]

    public init(
        parent: Parent? = nil,
        pullRequest: PullRequest? = nil,
        blockedBy: [Connected] = [],
        blocks: [Connected] = [],
        related: [Connected] = [],
        earlierDecisions: [EarlierDecision] = []
    ) {
        self.parent = parent
        self.pullRequest = pullRequest
        self.blockedBy = blockedBy
        self.blocks = blocks
        self.related = related
        self.earlierDecisions = earlierDecisions
    }

    struct Payload: Decodable {
        struct ParentPayload: Decodable {
            let identifier: String?
            let title: String?
            let done: Int?
            let total: Int?
            let children: [String]?
        }

        struct PullRequestPayload: Decodable {
            let number: Int?
            let url: String?
            let checks: String?
            let sentBack: Int?
        }

        struct ConnectedPayload: Decodable {
            let identifier: String?
            let title: String?
            let state: String?
        }

        struct DecisionPayload: Decodable {
            let at: String?
            let title: String?
            let answer: String?
        }

        let parent: ParentPayload?
        let pullRequest: PullRequestPayload?
        let blockedBy: [ConnectedPayload]?
        let blocks: [ConnectedPayload]?
        let related: [ConnectedPayload]?
        let earlierDecisions: [DecisionPayload]?
    }

    init(_ payload: Payload) {
        let connected: ([Payload.ConnectedPayload]?) -> [Connected] = { list in
            (list ?? []).compactMap { entry in entry.identifier.map { Connected(identifier: $0, title: entry.title, state: entry.state) } }
        }
        self.init(
            parent: payload.parent.flatMap { parent in
                parent.identifier.map {
                    Parent(identifier: $0, title: parent.title, done: parent.done ?? 0, total: parent.total ?? 0, children: parent.children ?? [])
                }
            },
            pullRequest: payload.pullRequest.flatMap { pullRequest in
                pullRequest.number.map {
                    PullRequest(
                        number: $0,
                        url: pullRequest.url.flatMap(URL.init(string:)),
                        checks: pullRequest.checks.flatMap(Reference.Checks.init(rawValue:)),
                        sentBack: pullRequest.sentBack ?? 0
                    )
                }
            },
            blockedBy: connected(payload.blockedBy),
            blocks: connected(payload.blocks),
            related: connected(payload.related),
            earlierDecisions: (payload.earlierDecisions ?? []).map {
                EarlierDecision(at: $0.at.flatMap { ISO8601DateFormatter().date(from: $0) }, title: $0.title, answer: $0.answer)
            }
        )
    }
}
