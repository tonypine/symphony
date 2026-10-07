import Foundation

/// A move the Director makes on an Inbox item (US2). Each opens its consequence sheet first (C17, P5, D12d); nothing
/// changes Linear until the sheet's button is pressed.
public enum InboxMove: String, CaseIterable, Equatable, Identifiable {
    case approvePlan
    case sendDecisions
    case approveAndMerge
    case sendToRework
    case signOff

    public var id: String { rawValue }

    /// The toolbar button: "…" where a sheet asks more.
    public var buttonTitle: String {
        switch self {
        case .approvePlan: "Approve Plan…"
        case .sendDecisions: "Send Decisions"
        case .approveAndMerge: "Approve and Merge…"
        case .sendToRework: "Send to Rework…"
        case .signOff: "Sign Off…"
        }
    }

    /// The sheet's action button, named with its verb.
    public var verb: String {
        switch self {
        case .approvePlan: "Approve Plan"
        case .sendDecisions: "Send Decisions"
        case .approveAndMerge: "Approve and Merge"
        case .sendToRework: "Send to Rework"
        case .signOff: "Sign Off"
        }
    }
}

/// A review's toolbar entry: a move, which opens its sheet, or a link.
public enum InboxCommand: Equatable {
    case move(InboxMove)
    case link(InboxAction)

    public var title: String {
        switch self {
        case let .move(move): move.buttonTitle
        case let .link(action): action.title
        }
    }
}

/// The actions over a review (P4): the buttons, the first one the prominent default, and the ⋯ menu.
public struct InboxToolbar: Equatable {
    public struct Button: Equatable {
        public var command: InboxCommand
        public var enabled: Bool
    }

    public var buttons: [Button]
    /// What the ⋯ menu holds; empty hides it.
    public var overflow: [InboxCommand]

    /// What Return in the list takes: the default button, while it is enabled.
    public var defaultCommand: InboxCommand? { buttons.first.flatMap { $0.enabled ? $0.command : nil } }

    /// The toolbar of `item`: a plan offers Approve Plan…, Send Decisions (on once a pick differs from the
    /// recommendation) and ⋯ Send to Rework…; a PR Approve and Merge… and Send to Rework…, with Open PR the default
    /// while a check is red (D2b); a final verification Sign Off…. Actions and clarify items keep their links.
    public static func toolbar(for item: InboxItem, picks: DecisionPicks = DecisionPicks()) -> InboxToolbar {
        let links = InboxAction.actions(for: item).map { Button(command: .link($0), enabled: true) }
        func move(_ move: InboxMove, enabled: Bool = true) -> Button { Button(command: .move(move), enabled: enabled) }
        switch item.kind {
        case .plan:
            let changed = picks.changed(item.review.decisions)
            let sendDecisions = item.review.decisions.isEmpty ? [] : [move(.sendDecisions, enabled: changed)]
            return InboxToolbar(buttons: [move(.approvePlan)] + sendDecisions + links, overflow: [.move(.sendToRework)])
        case .pr:
            let moves = [move(.approveAndMerge), move(.sendToRework)]
            if item.review.pullRequest?.hasRedCheck == true, let openPR = links.first, case .link(.openPR) = openPR.command {
                return InboxToolbar(buttons: [openPR] + moves + links.dropFirst(), overflow: [])
            }
            return InboxToolbar(buttons: moves + links, overflow: [])
        case .finalVerification:
            return InboxToolbar(buttons: [move(.signOff)] + links, overflow: [])
        case .action, .clarify:
            return InboxToolbar(buttons: links, overflow: [])
        }
    }
}

extension InboxReview {
    /// A plan's decisions, empty when its brief has none or didn't parse.
    public var decisions: [Decision] {
        if case let .parsed(parsed) = brief { return parsed.decisions }
        return []
    }
}

/// The Director's picks in a plan's decisions (C16), by decision index; a decision not picked keeps its recommended
/// option.
public struct DecisionPicks: Equatable {
    public var picks: [Int: Int]

    public init(picks: [Int: Int] = [:]) {
        self.picks = picks
    }

    /// The option shown picked in decision `index`: the Director's pick, else the recommended one.
    public func pick(_ index: Int, in decision: InboxReview.Decision) -> Int? {
        picks[index] ?? decision.initialPick
    }

    /// True once a pick differs from its decision's recommendation: Send Decisions turns on.
    public func changed(_ decisions: [InboxReview.Decision]) -> Bool {
        decisions.indices.contains { index in picks[index].map { $0 != decisions[index].initialPick } ?? false }
    }

    /// Each decision with its picked option, as the decisions comment lists them; a decision with nothing picked
    /// is left out.
    public func answers(_ decisions: [InboxReview.Decision]) -> [ControlAction.DecisionPick] {
        decisions.enumerated().compactMap { index, decision in
            guard let pick = pick(index, in: decision), decision.options.indices.contains(pick) else { return nil }
            return ControlAction.DecisionPick(question: decision.question, answer: decision.options[pick])
        }
    }
}

/// The consequence sheet of a move (C17, P5, D12d): the question as its title, what happens in Linear, what stays
/// the same, the options (Rework's required reason), and Cancel with the verb.
public struct ConsequenceSheet: Equatable, Identifiable {
    public static let waitingState = "Waiting on sub-tickets"
    public static let reviewState = "In Review"

    public var move: InboxMove
    /// The Inbox item's issue id.
    public var itemID: String
    public var identifier: String
    public var title: String
    public var happens: String
    public var stays: String
    /// The picks a decisions sheet posts, listed in it.
    public var picks: [ControlAction.DecisionPick]
    /// The state the move is expected to put the ticket in, nil when it stays (decisions on a plan in In Review).
    /// The banner follows Symphony's answer instead, which knows the workflow's states.
    public var targetState: String?

    public var id: String { "\(itemID):\(move.rawValue)" }
    public var verb: String { move.verb }
    /// Send to Rework uses the destructive style.
    public var isDestructive: Bool { move == .sendToRework }
    /// Send to Rework can't be sent without a reason.
    public var needsReason: Bool { move == .sendToRework }
    public var reasonPrompt: String { "Why does \(identifier) go back?" }

    public init(move: InboxMove, item: InboxItem, picks: DecisionPicks = DecisionPicks()) {
        self.move = move
        itemID = item.id
        identifier = item.identifier
        let id = item.identifier
        self.picks = []
        switch move {
        case .approvePlan:
            title = "Approve the plan of \(id)?"
            targetState = Self.waitingState
            happens = "Moves \(id) to \(Self.waitingState)" + Self.promotion(item.review.subTickets) + "."
            stays = picks.changed(item.review.decisions)
                ? "The plan stays as written: your changed picks are not sent. To have Symphony revise it first, choose Send Decisions instead."
                : "The plan stays as written. To change it, send decisions or comment on it in Linear instead."
        case .sendDecisions:
            title = "Send your decisions on \(id)?"
            // A plan waits in the Inbox in In Review or in the workflow's Human Review state, whatever its name.
            let humanReview = item.state.map { $0.caseInsensitiveCompare(Self.reviewState) != .orderedSame } ?? false
            targetState = humanReview ? Self.reviewState : nil
            self.picks = picks.answers(item.review.decisions)
            happens = (humanReview ? "Moves \(id) from \(item.state ?? "") to \(Self.reviewState), then posts" : "Posts")
                + " one comment on \(id) with your picks, and Symphony revises the plan from it."
            stays = "The plan isn't approved: it comes back to the Inbox once Symphony has revised it."
        case .approveAndMerge:
            title = "Move \(id) to Merging?"
            targetState = "Merging"
            happens = "Symphony turns on auto-merge, and GitHub merges the pull request once checks pass."
            stays = "Nothing merges while a check is red or pending, and the diff stays on GitHub."
        case .sendToRework:
            title = "Send \(id) to Rework?"
            targetState = "Rework"
            happens = item.kind == .plan
                ? "Posts your reason on \(id) and moves it to Rework: Symphony cancels the plan's sub-tickets still in Backlog and plans again."
                : "Posts your reason on \(id) and moves it to Rework: Symphony closes the PR and starts over."
            stays = "Your reason stays on the ticket as your comment, even after Undo."
        case .signOff:
            title = "Sign off \(id)?"
            targetState = "Done"
            happens = "Moves \(id) to Done; the parent's close-out run follows."
            stays = "Nothing else changes in Linear."
        }
    }

    /// " and promotes its 7 sub-tickets to Todo; SHOP-331 starts first", or nothing when no sub-ticket waits in
    /// Backlog.
    private static func promotion(_ tickets: [InboxReview.SubTicket]) -> String {
        let backlog = tickets.filter { ($0.state ?? "Backlog").caseInsensitiveCompare("Backlog") == .orderedSame }
        guard let first = backlog.first else { return "" }
        let count = backlog.count == 1 ? "its sub-ticket" : "its \(backlog.count) sub-tickets"
        return " and promotes \(count) to Todo; \(first.identifier) starts first"
    }

    /// Whether the sheet's button is on for `reason`.
    public func canSend(reason: String) -> Bool {
        !needsReason || !reason.trimmingWhitespace().isEmpty
    }

    /// The control request the sheet's button sends, nil while a required reason is missing.
    public func action(reason: String = "") -> ControlAction? {
        guard canSend(reason: reason) else { return nil }
        switch move {
        case .approvePlan: return .approvePlan(identifier)
        case .sendDecisions: return .decisions(identifier, picks: picks)
        case .approveAndMerge: return .approvePR(identifier)
        case .sendToRework: return .rework(identifier, reason: reason.trimmingWhitespace())
        case .signOff: return .signOff(identifier)
        }
    }

    /// What the sheet expects Symphony to answer, for an answer that didn't say.
    public var expectedOutcome: MoveOutcome { MoveOutcome(moved: targetState != nil, toState: targetState) }

    /// The banner once the move is made (C18), from Symphony's answer: Undo only after the ticket moved.
    public func banner(after outcome: MoveOutcome) -> InboxBanner {
        if outcome.moved {
            return InboxBanner(itemID: itemID, identifier: identifier, text: "Moved to \(outcome.toState ?? targetState ?? "its next state")", undo: true)
        }
        return InboxBanner(itemID: itemID, identifier: identifier, text: "Sent your decisions", undo: false)
    }
}

/// The banner at the foot of the Inbox after a move (C18): "Moved to Merging · Undo" for 10 s, or what went wrong.
public struct InboxBanner: Equatable, Identifiable {
    /// How long the banner, and its Undo, stay.
    public static let duration: TimeInterval = 10

    public enum Style: Equatable {
        case success, info, error
    }

    public let id = UUID()
    public var itemID: String
    public var identifier: String
    public var text: String
    /// Whether it offers Undo.
    public var undo: Bool
    public var style: Style

    public init(itemID: String, identifier: String, text: String, undo: Bool, style: Style = .success) {
        self.itemID = itemID
        self.identifier = identifier
        self.text = text
        self.undo = undo
        self.style = style
    }

    /// What VoiceOver announces once, when it appears.
    public var announcement: String { "\(identifier): \(text)" + (undo ? ". Undo is available for 10 seconds." : "") }

    /// The banner after Undo took a move back.
    public static func undone(itemID: String, identifier: String) -> InboxBanner {
        InboxBanner(itemID: itemID, identifier: identifier, text: "Moved back", undo: false, style: .info)
    }

    /// The banner for a request that failed, with Symphony's message.
    public static func failed(itemID: String, identifier: String, message: String) -> InboxBanner {
        InboxBanner(itemID: itemID, identifier: identifier, text: message, undo: false, style: .error)
    }

    public static func == (lhs: InboxBanner, rhs: InboxBanner) -> Bool {
        (lhs.itemID, lhs.identifier, lhs.text, lhs.undo, lhs.style) == (rhs.itemID, rhs.identifier, rhs.text, rhs.undo, rhs.style)
    }
}
