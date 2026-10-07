import Foundation

/// What waits on the Director, as `GET /api/v1/inbox` serves it (US1, D2a–D2e). Every field is optional in the
/// payload, so an item missing one never fails the whole list.
public struct InboxPayload: Equatable {
    public static let path = "api/v1/inbox"

    public var items: [InboxItem]

    public init(items: [InboxItem]) {
        self.items = items
    }

    /// The Inbox in a payload, nil when it isn't one (an error, or not JSON).
    public static func decode(_ data: Data) -> InboxPayload? {
        guard let payload = try? decoder.decode(Payload.self, from: data), payload.error == nil, let items = payload.items else {
            return nil
        }
        return InboxPayload(items: items.compactMap(InboxItem.init))
    }

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    struct Payload: Decodable {
        struct Failure: Decodable {
            let code: String?
        }

        let items: [InboxItem.Payload]?
        let error: Failure?
    }
}

/// One thing that waits on the Director.
public struct InboxItem: Equatable, Identifiable {
    /// What waits, in the order the Inbox groups them.
    public enum Kind: String, CaseIterable, Equatable {
        case plan
        case pr
        case finalVerification = "final_verification"
        case action
        case clarify

        /// The group's heading in the list.
        public var groupTitle: String {
            switch self {
            case .plan: "Plans"
            case .pr: "Pull requests"
            case .finalVerification: "Final verifications"
            case .action: "Actions"
            case .clarify: "Clarify"
            }
        }

        /// The kind in a row's VoiceOver label and the review's header.
        public var word: String {
            switch self {
            case .plan: "Plan"
            case .pr: "Pull request"
            case .finalVerification: "Final verification"
            case .action: "Action"
            case .clarify: "Clarify"
            }
        }

        /// The SF Symbol of the kind (design system §3.9).
        public var symbol: String {
            switch self {
            case .plan: "doc.text.magnifyingglass"
            case .pr: "arrow.triangle.pull"
            case .finalVerification: "checkmark.seal"
            case .action: "hand.raised"
            case .clarify: "questionmark.bubble"
            }
        }
    }

    /// The Linear issue id.
    public var id: String
    public var identifier: String
    public var title: String?
    public var repoKey: String?
    public var kind: Kind
    public var state: String?
    /// The one-line ask: the brief's headline, the request's title, or what the quality gate wants.
    public var ask: String
    /// How long it has waited, nil when Symphony couldn't tell.
    public var waitingSeconds: Int?
    public var url: URL?
    public var review: InboxReview

    public init(
        id: String,
        identifier: String,
        title: String? = nil,
        repoKey: String? = nil,
        kind: Kind,
        state: String? = nil,
        ask: String,
        waitingSeconds: Int? = nil,
        url: URL? = nil,
        review: InboxReview = InboxReview()
    ) {
        self.id = id
        self.identifier = identifier
        self.title = title
        self.repoKey = repoKey
        self.kind = kind
        self.state = state
        self.ask = ask
        self.waitingSeconds = waitingSeconds
        self.url = url
        self.review = review
    }

    /// The row's age: "3 h 12 min"; nil when unknown.
    public var age: String? { waitingSeconds.map(Overview.duration) }

    /// What VoiceOver reads for the row, as one element: "SHOP-330, Gift card checkout, plan, 3 hours 12 minutes".
    public var accessibilityLabel: String {
        [identifier, title, kind.word.lowercased(), waitingSeconds.map(Overview.spokenDuration)]
            .compactMap { $0 }
            .joined(separator: ", ")
    }

    struct Payload: Decodable {
        let issueId: String?
        let identifier: String?
        let title: String?
        let repoKey: String?
        let kind: String?
        let state: String?
        let ask: String?
        let waitingSeconds: Int?
        let url: String?
        let review: InboxReview.Payload?
    }

    init?(_ payload: Payload) {
        guard let identifier = payload.identifier ?? payload.issueId, let kind = payload.kind.flatMap(Kind.init(rawValue:)) else {
            return nil
        }
        self.init(
            id: payload.issueId ?? identifier,
            identifier: identifier,
            title: payload.title,
            repoKey: payload.repoKey,
            kind: kind,
            state: payload.state,
            ask: payload.ask ?? payload.title ?? identifier,
            waitingSeconds: payload.waitingSeconds,
            url: payload.url.flatMap(URL.init(string:)),
            review: payload.review.map(InboxReview.init) ?? InboxReview()
        )
    }
}

/// The review of an item (C15): which parts it has depends on its kind.
public struct InboxReview: Equatable {
    /// A plan's, PR's or final verification's `## Review brief`; nil when the ticket has none.
    public var brief: Brief?
    /// A plan's sub-tickets, in landing order.
    public var subTickets: [SubTicket]
    public var pullRequest: PullRequest?
    public var action: Action?
    public var clarify: Clarify?

    public init(brief: Brief? = nil, subTickets: [SubTicket] = [], pullRequest: PullRequest? = nil, action: Action? = nil, clarify: Clarify? = nil) {
        self.brief = brief
        self.subTickets = subTickets
        self.pullRequest = pullRequest
        self.action = action
        self.clarify = clarify
    }

    /// The brief in its parts, or as text when it didn't parse.
    public enum Brief: Equatable {
        case parsed(ParsedBrief)
        case raw(String)
    }

    public struct Link: Equatable, Hashable {
        public var label: String
        public var url: URL
    }

    public struct ReviewLine: Equatable {
        public var text: String
        public var links: [Link]
    }

    /// A decision (C16): its options, and the one recommended when the brief says which.
    public struct Decision: Equatable {
        public var question: String
        public var options: [String]
        public var recommendation: String?
        public var recommended: Int?

        /// The option picked to start with: the recommended one, else none.
        public var initialPick: Int? { recommended.flatMap { options.indices.contains($0) ? $0 : nil } }
    }

    public struct Move: Equatable {
        public var move: String
        public var text: String
    }

    public struct ParsedBrief: Equatable {
        public var headline: String?
        public var whatToReview: [ReviewLine]
        public var whatChanged: [String]
        public var decisions: [Decision]
        public var moves: [Move]
        public var supervisorCheck: String?
    }

    public struct SubTicket: Equatable {
        public var identifier: String
        public var title: String?
        public var state: String?
        public var url: URL?
    }

    public struct PullRequest: Equatable {
        /// The CI result: passed, failed or pending.
        public enum Result: String, Equatable {
            case passed, failed, pending
        }

        public var url: URL?
        public var ci: Result?
        public var qaVerdict: String?
        public var qaReport: URL?
        public var gateVerdict: String?
        public var gateMode: String?
        public var files: Int?
        public var additions: Int?
        public var deletions: Int?

        /// A red check: CI failed, QA failed or blocked, or the gate asked for rework.
        public var hasRedCheck: Bool {
            ci == .failed || ["fail", "blocked"].contains(qaVerdict ?? "") || gateVerdict == "rework"
        }

        /// "3 files, +120 −4", nil while the gate hasn't measured it.
        public var changeLine: String? {
            guard let files else { return nil }
            return "\(files) file\(files == 1 ? "" : "s"), +\(additions ?? 0) −\(deletions ?? 0)"
        }
    }

    public struct Action: Equatable {
        public var title: String?
        public var question: String?
        public var why: String?
        public var unblocks: String?
        public var estMinutes: Int?
        public var steps: [String]
        public var options: [Option]

        public struct Option: Equatable {
            public var label: String
            public var effect: String?
            public var recommended: Bool
        }

        /// "About 5 min", nil when unknown.
        public var timeLine: String? { estMinutes.map { "About \($0) min" } }

        /// What Copy Steps puts on the clipboard: the numbered steps, else the numbered options.
        public var copyText: String? {
            let lines = steps.isEmpty
                ? options.map { [$0.label, $0.effect].compactMap { $0 }.joined(separator: ": ") }
                : steps
            guard !lines.isEmpty else { return nil }
            return lines.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        }
    }

    public struct Clarify: Equatable {
        /// True while the gate holds the ticket for answers, false once it skipped it.
        public var held: Bool
        public var score: Int?
        public var passThreshold: Int?
        public var round: Int?
        public var maxRounds: Int?
        public var found: String?
        public var questions: [String]

        /// "3 of 10, passes at 6".
        public var scoreLine: String? {
            guard let score else { return nil }
            return "\(score) of 10" + (passThreshold.map { ", passes at \($0)" } ?? "")
        }

        /// "Round 1 of 2".
        public var roundLine: String? {
            guard let round, round > 0 else { return nil }
            return "Round \(round)" + (maxRounds.map { " of \($0)" } ?? "")
        }

        public var nextLine: String {
            held
                ? "Symphony scores the ticket again once it changes, and starts it when it passes."
                : "Symphony skips the ticket until it changes. Edit it in Linear and it is scored again on the next poll."
        }
    }

    struct Payload: Decodable {
        struct LinkPayload: Decodable {
            let label: String?
            let url: String?
        }

        struct LinePayload: Decodable {
            let text: String?
            let links: [LinkPayload]?
        }

        struct DecisionPayload: Decodable {
            let question: String?
            let options: [String]?
            let recommendation: String?
            let recommended: Int?
        }

        struct MovePayload: Decodable {
            let move: String?
            let text: String?
        }

        struct BriefPayload: Decodable {
            let format: String?
            let markdown: String?
            let headline: String?
            let whatToReview: [LinePayload]?
            let whatChanged: [String]?
            let decisions: [DecisionPayload]?
            let moves: [MovePayload]?
            let supervisorCheck: String?
        }

        struct SubTicketPayload: Decodable {
            let identifier: String?
            let title: String?
            let state: String?
            let url: String?
        }

        struct PullRequestPayload: Decodable {
            struct QA: Decodable {
                let verdict: String?
                let reportUrl: String?
            }

            struct Gate: Decodable {
                let verdict: String?
                let mode: String?
            }

            struct Change: Decodable {
                let files: Int?
                let additions: Int?
                let deletions: Int?
            }

            let url: String?
            let ci: String?
            let qa: QA?
            let gate: Gate?
            let change: Change?
        }

        struct OptionPayload: Decodable {
            let label: String?
            let effect: String?
            let recommended: Bool?
        }

        // A plan, PR or final verification.
        let brief: BriefPayload?
        let subTickets: [SubTicketPayload]?
        let pullRequest: PullRequestPayload?
        // An action.
        let title: String?
        let question: String?
        let why: String?
        let unblocks: String?
        let estMinutes: Int?
        let steps: [String]?
        let options: [OptionPayload]?
        // A clarify item.
        let held: Bool?
        let score: Int?
        let passThreshold: Int?
        let round: Int?
        let maxRounds: Int?
        let found: String?
        let questions: [String]?
    }

    init(_ payload: Payload) {
        self.init(
            brief: payload.brief.flatMap(Self.brief),
            subTickets: (payload.subTickets ?? []).compactMap { ticket in
                ticket.identifier.map {
                    SubTicket(identifier: $0, title: ticket.title, state: ticket.state, url: ticket.url.flatMap(URL.init(string:)))
                }
            },
            pullRequest: payload.pullRequest.map { pr in
                PullRequest(
                    url: pr.url.flatMap(URL.init(string:)),
                    ci: pr.ci.flatMap(PullRequest.Result.init(rawValue:)),
                    qaVerdict: pr.qa?.verdict,
                    qaReport: pr.qa?.reportUrl.flatMap(URL.init(string:)),
                    gateVerdict: pr.gate?.verdict,
                    gateMode: pr.gate?.mode,
                    files: pr.change?.files,
                    additions: pr.change?.additions,
                    deletions: pr.change?.deletions
                )
            },
            action: payload.steps == nil && payload.options == nil && payload.why == nil ? nil : Action(
                title: payload.title,
                question: payload.question,
                why: payload.why,
                unblocks: payload.unblocks,
                estMinutes: payload.estMinutes,
                steps: payload.steps ?? [],
                options: (payload.options ?? []).compactMap { option in
                    option.label.map { Action.Option(label: $0, effect: option.effect, recommended: option.recommended ?? false) }
                }
            ),
            clarify: payload.held.map { held in
                Clarify(
                    held: held,
                    score: payload.score,
                    passThreshold: payload.passThreshold,
                    round: payload.round,
                    maxRounds: payload.maxRounds,
                    found: payload.found,
                    questions: payload.questions ?? []
                )
            }
        )
    }

    private static func brief(_ payload: Payload.BriefPayload) -> Brief? {
        guard payload.format == "parsed" else { return payload.markdown.map(Brief.raw) }
        return .parsed(ParsedBrief(
            headline: payload.headline,
            whatToReview: (payload.whatToReview ?? []).map { line in
                ReviewLine(
                    text: line.text ?? "",
                    links: (line.links ?? []).compactMap { link in
                        link.url.flatMap(URL.init(string:)).map { Link(label: link.label ?? $0.absoluteString, url: $0) }
                    }
                )
            },
            whatChanged: payload.whatChanged ?? [],
            decisions: (payload.decisions ?? []).compactMap { decision in
                decision.question.map {
                    Decision(question: $0, options: decision.options ?? [], recommendation: decision.recommendation, recommended: decision.recommended)
                }
            },
            moves: (payload.moves ?? []).compactMap { move in
                guard let name = move.move, let text = move.text else { return nil }
                return Move(move: name, text: text)
            },
            supervisorCheck: payload.supervisorCheck
        ))
    }
}

/// The Inbox list under a scope (P4, P6): groups by kind, oldest first inside each, and what the scope hides.
public struct InboxList: Equatable {
    public struct Group: Equatable, Identifiable {
        public var kind: InboxItem.Kind
        public var items: [InboxItem]
        public var id: String { kind.rawValue }
        public var title: String { kind.groupTitle }
    }

    public static let emptyTitle = "Nothing waits on you."
    public static let openOverviewTitle = "Open Overview"

    public var groups: [Group]
    /// Items the scope hides; the sidebar badge still counts them.
    public var hiddenCount: Int
    /// Every item, whatever the scope: the sidebar badge's count.
    public var totalCount: Int

    /// `answered` are the items the Director just moved, by issue id: they leave the list at once, before Symphony's
    /// next poll drops them.
    public init(items: [InboxItem], scope: OverviewScope = .all, answered: Set<String> = []) {
        let items = items.filter { !answered.contains($0.id) }
        let shown = items.filter { scope.includes($0.repoKey) }
        groups = InboxItem.Kind.allCases.compactMap { kind in
            let inKind = shown.enumerated()
                .filter { $0.element.kind == kind }
                // Oldest first; an item whose wait is unknown goes last, in Symphony's order.
                .sorted { ($0.element.waitingSeconds ?? -1, -$0.offset) > ($1.element.waitingSeconds ?? -1, -$1.offset) }
                .map(\.element)
            return inKind.isEmpty ? nil : Group(kind: kind, items: inKind)
        }
        hiddenCount = items.count - shown.count
        totalCount = items.count
    }

    /// The items in list order, for ↑↓ and for moving to the next item.
    public var ordered: [InboxItem] { groups.flatMap(\.items) }

    public var isEmpty: Bool { groups.isEmpty }

    /// "2 more in other repos", nil when the scope hides nothing.
    public var hiddenLine: String? {
        switch hiddenCount {
        case 0: nil
        case 1: "1 more in another repo"
        default: "\(hiddenCount) more in other repos"
        }
    }

    /// The item to show: the one selected while it is still listed, else the first.
    public func selection(_ id: String?) -> InboxItem? {
        ordered.first { $0.id == id } ?? ordered.first
    }

    /// The item listed after `id`, or before it when it is last: where the selection goes when `id` leaves.
    public func neighbor(of id: String) -> InboxItem? {
        let items = ordered
        guard let index = items.firstIndex(where: { $0.id == id }) else { return items.first }
        if index + 1 < items.count { return items[index + 1] }
        return index > 0 ? items[index - 1] : nil
    }
}

/// The actions a review offers, in the toolbar over it (P4), the first the default.
public enum InboxAction: Equatable {
    case openInLinear(URL)
    case openPR(URL)
    case copySteps(String)
    case editInLinear(URL)

    public var title: String {
        switch self {
        case .openInLinear: "Open in Linear"
        case .openPR: "Open PR"
        case .copySteps: "Copy Steps"
        case .editInLinear: "Edit in Linear"
        }
    }

    /// The actions of `item`: Open PR first on a PR with a red check (D2b), Open in Linear first on an action
    /// (D2c), Edit in Linear on a clarify item (D2d).
    public static func actions(for item: InboxItem) -> [InboxAction] {
        let linear = item.url.map(InboxAction.openInLinear)
        switch item.kind {
        case .plan, .finalVerification:
            return [linear].compactMap { $0 }
        case .pr:
            let pr = item.review.pullRequest?.url.map(InboxAction.openPR)
            return [pr, linear].compactMap { $0 }
        case .action:
            return [linear, item.review.action?.copyText.map(InboxAction.copySteps)].compactMap { $0 }
        case .clarify:
            return [item.url.map(InboxAction.editInLinear)].compactMap { $0 }
        }
    }
}
