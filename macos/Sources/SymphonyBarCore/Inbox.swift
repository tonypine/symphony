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
        case action
        case clarify
        /// A ticket an access hold pauses in place, waiting on an Unblock.
        case blocked

        /// The group's heading in the list.
        public var groupTitle: String {
            switch self {
            case .plan: "Plans"
            case .pr: "Pull requests"
            case .action: "Actions"
            case .clarify: "Clarify"
            case .blocked: "Blocked"
            }
        }

        /// The kind in a row's VoiceOver label and the review's header.
        public var word: String {
            switch self {
            case .plan: "Plan"
            case .pr: "Pull request"
            case .action: "Action"
            case .clarify: "Clarify"
            case .blocked: "Blocked"
            }
        }

        /// The SF Symbol of the kind (design system §3.9).
        public var symbol: String {
            switch self {
            case .plan: "doc.text.magnifyingglass"
            case .pr: "arrow.triangle.pull"
            case .action: "hand.raised"
            case .clarify: "questionmark.bubble"
            case .blocked: "hand.raised.slash"
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
    /// What each ticket or pull request the item's text mentions is, keyed by the mention as written; empty from a
    /// Symphony that doesn't resolve them.
    public var references: [String: Reference]
    /// Where the item's ticket sits; nil from a Symphony that doesn't say.
    public var context: TicketContext?

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
        review: InboxReview = InboxReview(),
        references: [String: Reference] = [:],
        context: TicketContext? = nil
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
        self.references = references
        self.context = context
    }

    /// The row's age: "3 h 12 min"; nil when unknown.
    public var age: String? { waitingSeconds.map(Overview.duration) }

    /// True for a request that offers options to answer with: it reads "Decision" (DD-7). An older hand-written
    /// request with steps stays an action.
    public var isDecision: Bool { kind == .action && review.action?.options.isEmpty == false }

    /// The kind in the review's badge and the row's VoiceOver label: "Decision" for a request with options.
    public var kindWord: String { isDecision ? "Decision" : kind.word }

    /// What VoiceOver reads for the row, as one element: "SHOP-330, Gift card checkout, plan, 3 hours 12 minutes".
    public var accessibilityLabel: String {
        [identifier, title, kindWord.lowercased(), waitingSeconds.map(Overview.spokenDuration)]
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
        let references: [String: Reference.Payload]?
        let context: TicketContext.Payload?
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
            review: payload.review.map(InboxReview.init) ?? InboxReview(),
            references: (payload.references ?? [:]).mapValues(Reference.init),
            context: payload.context.map(TicketContext.init)
        )
    }
}

/// The review of an item (C15): which parts it has depends on its kind.
public struct InboxReview: Equatable {
    /// A plan's or PR's `## Review brief`; nil when the ticket has none.
    public var brief: Brief?
    /// A plan's sub-tickets, in landing order.
    public var subTickets: [SubTicket]
    public var pullRequest: PullRequest?
    public var action: Action?
    public var clarify: Clarify?
    public var blocked: Blocked?

    public init(brief: Brief? = nil, subTickets: [SubTicket] = [], pullRequest: PullRequest? = nil, action: Action? = nil, clarify: Clarify? = nil, blocked: Blocked? = nil) {
        self.brief = brief
        self.subTickets = subTickets
        self.pullRequest = pullRequest
        self.action = action
        self.clarify = clarify
        self.blocked = blocked
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

        /// A red check: CI failed, or QA failed or blocked.
        public var hasRedCheck: Bool {
            ci == .failed || ["fail", "blocked"].contains(qaVerdict ?? "")
        }
    }

    public struct Action: Equatable {
        public var title: String?
        public var question: String?
        public var why: String?
        /// What waits or repeats until someone answers; nil on an older request.
        public var ifUnanswered: String? = nil
        public var unblocks: String?
        public var estMinutes: Int?
        public var steps: [String]
        public var options: [Option]
        /// Why the recommended option is the one to pick; nil on an older request.
        public var recommendationReason: String? = nil
        /// The id of the request comment a decision answers: its reply goes under it. Nil for a request Symphony
        /// can't answer from the Inbox.
        public var commentID: String?
        /// The state confirming the request moves the ticket to: `Merging` for a merge confirmation, nil for an
        /// ordinary decision, which moves nothing.
        public var confirm: String?

        public struct Option: Equatable {
            public var label: String
            public var effect: String?
            public var recommended: Bool
            /// Up to three things picking the option gains, costs or risks.
            public var tradeoffs: [Tradeoff] = []
        }

        /// One line on what an option gains (`good`), costs (`cost`) or risks (`risk`).
        public struct Tradeoff: Equatable {
            public enum Kind: String, Equatable {
                case good, cost, risk

                /// The word VoiceOver reads before the tag's text.
                public var word: String {
                    switch self {
                    case .good: "Good"
                    case .cost: "Cost"
                    case .risk: "Risk"
                    }
                }

                /// The tag's symbol (N8): its shape tells the kind apart without the color.
                public var symbol: String {
                    switch self {
                    case .good: "checkmark.circle"
                    case .cost: "exclamationmark.triangle"
                    case .risk: "xmark.circle"
                    }
                }

                /// The status color the symbol takes.
                public var status: DesignTokens.Status {
                    switch self {
                    case .good: .done
                    case .cost: .you
                    case .risk: .problem
                    }
                }
            }

            public var kind: Kind
            public var text: String
        }

        /// The why as the What happened card tells it (N6): its paragraphs, split on blank lines, at most two.
        public var whyParagraphs: [String] {
            var paragraphs: [String] = []
            var lines: [String] = []
            for line in (why ?? "").components(separatedBy: .newlines) + [""] {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    lines.append(trimmed)
                } else if !lines.isEmpty {
                    paragraphs.append(lines.joined(separator: "\n"))
                    lines = []
                }
            }
            return Array(paragraphs.prefix(2))
        }

        /// The pick of the write-in (N11), the card after the last option: the Director answers in their own words.
        public var writeInIndex: Int { options.count }

        /// The Options card's hint, counting the write-in after the options: "Press 1–4 to pick · ⌘↩ to send" for
        /// three options; nil without options.
        public var keyHint: String? {
            options.isEmpty ? nil : "Press 1–\(min(writeInIndex + 1, 9)) to pick · ⌘↩ to send"
        }

        /// The option a number key picks: "2" picks the second, and the number after the last option the write-in;
        /// nil for any other key, a number past the write-in, or a request without options.
        public func optionIndex(forKey key: Character) -> Int? {
            guard !options.isEmpty, let number = key.wholeNumberValue, number >= 1, number <= min(writeInIndex + 1, 9) else { return nil }
            return number - 1
        }

        /// The request as one decision (C16), so the Inbox's picks answer it: its question and its options, the
        /// recommended one picked to start with. Nil when the request offers no options to answer with.
        public var decision: Decision? {
            guard !options.isEmpty else { return nil }
            return Decision(
                question: question ?? "",
                options: options.map(\.label),
                recommendation: options.first(where: \.recommended)?.label,
                recommended: options.firstIndex(where: \.recommended)
            )
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

    /// A ticket an access hold pauses in place (state-machine §Holds): the reason the hold recorded, and what
    /// clears it. Only an access hold is listed — a dependency or fix-ticket hold clears on its own.
    public struct Blocked: Equatable {
        public var reason: String?
        public var clearingCondition: String?

        /// What the review says under the reason: what clears the hold.
        public var nextLine: String {
            clearingCondition.map { "Clears \($0)." } ?? "Symphony lifts the hold when what it waits on clears."
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

            let url: String?
            let ci: String?
            let qa: QA?
        }

        struct TradeoffPayload: Decodable {
            let kind: String?
            let text: String?
        }

        struct OptionPayload: Decodable {
            let label: String?
            let effect: String?
            let recommended: Bool?
            let tradeoffs: [TradeoffPayload]?
        }

        // A plan or PR.
        let brief: BriefPayload?
        let subTickets: [SubTicketPayload]?
        let pullRequest: PullRequestPayload?
        // An action.
        let title: String?
        let question: String?
        let why: String?
        let ifUnanswered: String?
        let unblocks: String?
        let estMinutes: Int?
        let steps: [String]?
        let options: [OptionPayload]?
        let recommendationReason: String?
        /// The request comment a decision answers.
        let commentId: String?
        /// The state confirming the request moves the ticket to.
        let confirm: String?
        // A clarify item.
        let held: Bool?
        let score: Int?
        let passThreshold: Int?
        let round: Int?
        let maxRounds: Int?
        let found: String?
        let questions: [String]?
        // A blocked item.
        let reason: String?
        let clearingCondition: String?
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
                    qaReport: pr.qa?.reportUrl.flatMap(URL.init(string:))
                )
            },
            action: payload.steps == nil && payload.options == nil && payload.why == nil ? nil : Action(
                title: payload.title,
                question: payload.question,
                why: payload.why,
                ifUnanswered: payload.ifUnanswered,
                unblocks: payload.unblocks,
                estMinutes: payload.estMinutes,
                steps: payload.steps ?? [],
                options: (payload.options ?? []).compactMap { option in
                    option.label.map {
                        Action.Option(
                            label: $0,
                            effect: option.effect,
                            recommended: option.recommended ?? false,
                            tradeoffs: (option.tradeoffs ?? []).compactMap { tradeoff in
                                guard let kind = tradeoff.kind.flatMap(Action.Tradeoff.Kind.init(rawValue:)), let text = tradeoff.text else { return nil }
                                return Action.Tradeoff(kind: kind, text: text)
                            }
                        )
                    }
                },
                recommendationReason: payload.recommendationReason,
                commentID: payload.commentId,
                confirm: payload.confirm
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
            },
            blocked: payload.reason == nil && payload.clearingCondition == nil
                ? nil
                : Blocked(reason: payload.reason, clearingCondition: payload.clearingCondition)
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
            }
        ))
    }
}

/// The Inbox list under a scope (P4, P6): groups by kind, oldest first inside each, and what the scope hides.
public struct InboxList: Equatable {
    public struct Group: Equatable, Identifiable {
        public var kind: InboxItem.Kind
        public var items: [InboxItem]
        /// True for the requests with options, listed apart from the older actions with steps (DD-7).
        public var decisions = false
        public var id: String { decisions ? "decision" : kind.rawValue }
        public var title: String { decisions ? "Decisions" : kind.groupTitle }
    }

    public static let emptyTitle = "Nothing waits on you."
    public static let openOverviewTitle = "Open Overview"

    public var groups: [Group]
    /// Items the scope hides; the sidebar badge still counts them.
    public var hiddenCount: Int
    /// Every item, whatever the scope: the sidebar badge's count.
    public var totalCount: Int

    public init(items: [InboxItem], scope: OverviewScope = .all) {
        let shown = items.filter { scope.includes($0.repoKey) }
        groups = InboxItem.Kind.allCases.flatMap { kind in
            let inKind = shown.enumerated()
                .filter { $0.element.kind == kind }
                // Oldest first; an item whose wait is unknown goes last, in Symphony's order.
                .sorted { ($0.element.waitingSeconds ?? -1, -$0.offset) > ($1.element.waitingSeconds ?? -1, -$1.offset) }
                .map(\.element)
            // Decisions come before the older actions with steps, each under its own heading.
            return [
                Group(kind: kind, items: inKind.filter(\.isDecision), decisions: true),
                Group(kind: kind, items: inKind.filter { !$0.isDecision }),
            ].filter { !$0.items.isEmpty }
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
        case .plan:
            return [linear].compactMap { $0 }
        case .pr:
            let pr = item.review.pullRequest?.url.map(InboxAction.openPR)
            return [pr, linear].compactMap { $0 }
        case .action:
            return [linear, item.review.action?.copyText.map(InboxAction.copySteps)].compactMap { $0 }
        case .clarify:
            return [item.url.map(InboxAction.editInLinear)].compactMap { $0 }
        case .blocked:
            return [linear].compactMap { $0 }
        }
    }
}
