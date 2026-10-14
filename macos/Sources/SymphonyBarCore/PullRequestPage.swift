import Foundation

/// A pull request's page, as `GET /api/v1/pull_requests/:repo_key/:number` serves it (D15, DS8): its story, the
/// verdicts Symphony recorded on it, what it changes by area (never as a file list), how healthy it is and its size.
/// When Symphony couldn't read GitHub, the page carries only what Linear and Symphony's records know
/// (`gitHubAvailable` false). Every field is optional in the payload, so an older or newer Symphony never fails the
/// whole page.
public struct PullRequestPage: Equatable {
    public enum State: String, Equatable {
        case open
        case merged
        case closed
    }

    /// The ticket the pull request belongs to.
    public struct Ticket: Equatable {
        public var identifier: String
        public var title: String?
        public var state: String?
        /// What it waits on, in the ticket page's words ("you", "a blocker: TP-1", "CI"); nil while it runs or once done.
        public var waitingOn: String?
    }

    /// One Code Review or QA verdict Symphony recorded on the pull request.
    public struct Verdict: Equatable {
        public enum Kind: String, Equatable {
            case codeReview = "code_review"
            case qa
        }

        public var at: Date?
        public var kind: Kind
        /// The outcome as Symphony records it: `approve`, `request_changes`, `block`, `pass`, `fail`, `blocked`…
        public var verdict: String
        /// The verdict's one-line summary.
        public var reason: String?
    }

    /// The changed files of one area: Agent instructions, App, Server, Documentation, Tests or Other.
    public struct Area: Equatable {
        public var name: String
        public var files: Int
        public var additions: Int
        public var deletions: Int
    }

    public struct Health: Equatable {
        public struct Checks: Equatable {
            /// The outcome of the head's checks; nil when it has none.
            public var state: Reference.Checks?
            public var passed: Int
            public var failed: Int
            public var pending: Int
        }

        public struct CodeReview: Equatable {
            /// The latest Code Review verdict.
            public var verdict: String
            /// How many heads Code Review judged.
            public var round: Int
        }

        /// Another open pull request Symphony tracks that changes one of the same files.
        public struct Overlap: Equatable {
            public var number: Int
            public var ticket: String?
        }

        /// Nil when GitHub couldn't be read.
        public var checks: Checks?
        public var codeReview: CodeReview?
        /// The latest QA verdict.
        public var qa: String?
        public var overlaps: [Overlap]
    }

    public struct Size: Equatable {
        public var files: Int
        public var additions: Int
        public var deletions: Int
        public var commits: Int
    }

    public var number: Int
    public var url: URL?
    public var title: String?
    public var repoKey: String?
    public var ticket: Ticket?
    /// False when Symphony couldn't read GitHub.
    public var gitHubAvailable: Bool
    /// Nil when GitHub couldn't be read.
    public var state: State?
    public var reviewState: Reference.PullRequest.ReviewState
    public var openedAt: Date?
    public var lastPushedAt: Date?
    public var mergedAt: Date?
    /// The body's `## This PR` section as plain text, else its first paragraph.
    public var summary: String?
    /// Oldest first.
    public var reviewHistory: [Verdict]
    public var areas: [Area]
    public var health: Health
    /// Nil when GitHub couldn't be read.
    public var size: Size?

    /// The page's path for pull request `number` of the repo `repoKey`.
    public static func path(repoKey: String, number: Int) -> String {
        let key = repoKey.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? repoKey
        return "api/v1/pull_requests/\(key)/\(number)"
    }

    /// The page in a payload, nil when it isn't one (an error, no number, or not JSON).
    public static func decode(_ data: Data) -> PullRequestPage? {
        guard let payload = try? decoder.decode(Payload.self, from: data), payload.error == nil, let number = payload.number else {
            return nil
        }
        return PullRequestPage(number: number, payload: payload)
    }

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    private init(number: Int, payload: Payload) {
        let date: (String?) -> Date? = { $0.flatMap(TicketPage.date) }
        self.number = number
        url = payload.url.flatMap(URL.init(string:))
        title = payload.title
        repoKey = payload.repoKey
        ticket = payload.ticket.flatMap { ticket in
            ticket.identifier.map { Ticket(identifier: $0, title: ticket.title, state: ticket.state, waitingOn: ticket.waitingOn) }
        }
        gitHubAvailable = payload.github != "unavailable"
        state = payload.state.flatMap(State.init(rawValue:))
        reviewState = payload.reviewState.flatMap(Reference.PullRequest.ReviewState.init(rawValue:)) ?? .open
        openedAt = date(payload.openedAt)
        lastPushedAt = date(payload.lastPushedAt)
        mergedAt = date(payload.mergedAt)
        summary = payload.summary
        reviewHistory = (payload.reviewHistory ?? []).compactMap { entry in
            guard let kind = entry.kind.flatMap(Verdict.Kind.init(rawValue:)), let verdict = entry.verdict else { return nil }
            return Verdict(at: date(entry.at), kind: kind, verdict: verdict, reason: entry.reason)
        }
        areas = (payload.areas ?? []).compactMap { area in
            area.name.map { Area(name: $0, files: area.files ?? 0, additions: area.additions ?? 0, deletions: area.deletions ?? 0) }
        }
        let health = payload.health
        self.health = Health(
            checks: health?.checks.map {
                Health.Checks(
                    state: $0.state.flatMap(Reference.Checks.init(rawValue:)),
                    passed: $0.passed ?? 0,
                    failed: $0.failed ?? 0,
                    pending: $0.pending ?? 0
                )
            },
            codeReview: health?.codeReview.flatMap { review in
                review.verdict.map { Health.CodeReview(verdict: $0, round: review.round ?? 0) }
            },
            qa: health?.qa,
            overlaps: (health?.overlaps ?? []).compactMap { overlap in overlap.number.map { Health.Overlap(number: $0, ticket: overlap.ticket) } }
        )
        size = payload.size.map {
            Size(files: $0.files ?? 0, additions: $0.additions ?? 0, deletions: $0.deletions ?? 0, commits: $0.commits ?? 0)
        }
    }

    struct Payload: Decodable {
        struct Failure: Decodable {
            let code: String?
        }

        struct TicketPayload: Decodable {
            let identifier: String?
            let title: String?
            let state: String?
            let waitingOn: String?
        }

        struct VerdictPayload: Decodable {
            let at: String?
            let kind: String?
            let verdict: String?
            let reason: String?
        }

        struct AreaPayload: Decodable {
            let name: String?
            let files: Int?
            let additions: Int?
            let deletions: Int?
        }

        struct HealthPayload: Decodable {
            struct ChecksPayload: Decodable {
                let state: String?
                let passed: Int?
                let failed: Int?
                let pending: Int?
            }

            struct CodeReviewPayload: Decodable {
                let verdict: String?
                let round: Int?
            }

            struct OverlapPayload: Decodable {
                let number: Int?
                let ticket: String?
            }

            let checks: ChecksPayload?
            let codeReview: CodeReviewPayload?
            let qa: String?
            let overlaps: [OverlapPayload]?
        }

        struct SizePayload: Decodable {
            let files: Int?
            let additions: Int?
            let deletions: Int?
            let commits: Int?
        }

        let error: Failure?
        let number: Int?
        let url: String?
        let title: String?
        let repoKey: String?
        let ticket: TicketPayload?
        let github: String?
        let state: String?
        let reviewState: String?
        let openedAt: String?
        let lastPushedAt: String?
        let mergedAt: String?
        let summary: String?
        let reviewHistory: [VerdictPayload]?
        let areas: [AreaPayload]?
        let health: HealthPayload?
        let size: SizePayload?
    }
}

/// What a read of a pull request's page got (`LiveAPIClient.pullRequestPage(repoKey:number:)`).
public enum PullRequestPageResult: Equatable {
    case loaded(PullRequestPage)
    /// Symphony doesn't know the repo, or GitHub doesn't have the pull request.
    case notFound
    /// The Symphony running predates the page (`EndpointPlaceholder.updateSymphony`).
    case unsupported
    case failed(String)

    public init(_ answer: APIAnswer) {
        switch answer {
        case let .answered(data, 200):
            self = PullRequestPage.decode(data).map(Self.loaded) ?? .failed("Symphony sent a pull request page that couldn't be read")
        case let .answered(data, 404):
            // An older Symphony has no such route: its 404 isn't one of the page's own.
            let code = (try? PullRequestPage.decoder.decode(PullRequestPage.Payload.self, from: data))?.error?.code
            self = ["not_found", "unknown_repo"].contains(code) ? .notFound : .unsupported
        case let .answered(_, statusCode):
            self = .failed("Symphony answered with HTTP \(statusCode)")
        case .unreachable:
            self = .failed("Symphony isn't answering")
        }
    }
}
