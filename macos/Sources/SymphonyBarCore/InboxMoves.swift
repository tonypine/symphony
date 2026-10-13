import Foundation

/// A move the Director makes on an Inbox item (US2). Each opens its consequence sheet first (C17, P5, D12d); nothing
/// changes Linear until the sheet's button is pressed.
public enum InboxMove: String, CaseIterable, Equatable, Identifiable {
    case approvePlan
    case sendDecisions
    case approveAndMerge
    case sendToRework
    case restart
    case signOff
    /// Answers a decision request: the ticket continues in its phase, or the answer directs a move.
    case decide
    case unblock

    public var id: String { rawValue }

    /// The toolbar button: "…" where a sheet asks more.
    public var buttonTitle: String {
        switch self {
        case .approvePlan: "Approve Plan…"
        case .sendDecisions: "Send Decisions"
        case .approveAndMerge: "Approve and Merge…"
        case .sendToRework: "Send to Rework…"
        case .restart: "Restart…"
        case .signOff: "Sign Off…"
        case .decide: "Send Decision…"
        case .unblock: "Unblock…"
        }
    }

    /// The sheet's action button, named with its verb.
    public var verb: String {
        switch self {
        case .approvePlan: "Approve Plan"
        case .sendDecisions: "Send Decisions"
        case .approveAndMerge: "Approve and Merge"
        case .sendToRework: "Send to Rework"
        case .restart: "Restart"
        case .signOff: "Sign Off"
        case .decide: "Send Decision"
        case .unblock: "Unblock"
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
    /// recommendation) and ⋯ Send to Rework… and Restart…; a PR Approve and Merge… and Send to Rework…, with Open PR
    /// the default while a check is red (D2b), and ⋯ Restart…; a final verification Sign Off…; a blocked ticket
    /// Unblock…. Actions and clarify items keep their links. Restart (the human-only full reset) sits under ⋯ on
    /// both, so it takes a deliberate trip through the menu and its consequence sheet. An action carrying an
    /// answerable decision offers Send Decision…, with ⋯ Send to Rework… answering it as a redirect; another action,
    /// and a clarify item, keep their links, but an action whose options are listed in its card drops the Copy Steps
    /// link that would only repeat them.
    public static func toolbar(for item: InboxItem, picks: DecisionPicks = DecisionPicks()) -> InboxToolbar {
        let links = InboxAction.actions(for: item).map { Button(command: .link($0), enabled: true) }
        func move(_ move: InboxMove, enabled: Bool = true) -> Button { Button(command: .move(move), enabled: enabled) }
        let restart: [InboxCommand] = [.move(.restart)]
        switch item.kind {
        case .plan:
            let changed = picks.changed(item.review.decisions)
            let sendDecisions = item.review.decisions.isEmpty ? [] : [move(.sendDecisions, enabled: changed)]
            return InboxToolbar(
                buttons: [move(.approvePlan)] + sendDecisions + links,
                overflow: [.move(.sendToRework)] + restart
            )
        case .pr:
            let moves = [move(.approveAndMerge), move(.sendToRework)]
            if item.review.pullRequest?.hasRedCheck == true, let openPR = links.first, case .link(.openPR) = openPR.command {
                return InboxToolbar(buttons: [openPR] + moves + links.dropFirst(), overflow: restart)
            }
            return InboxToolbar(buttons: moves + links, overflow: restart)
        case .finalVerification:
            return InboxToolbar(buttons: [move(.signOff)] + links, overflow: [])
        case .blocked:
            return InboxToolbar(buttons: [move(.unblock)] + links, overflow: [])
        case .action:
            let action = item.review.action
            // A request's options are shown and picked in its card, so its Copy Steps link (which would list the
            // same options) is left out; a steps-only action keeps it.
            let actionLinks = links.filter { button in
                if case .link(.copySteps) = button.command, action?.options.isEmpty == false { return false }
                return true
            }
            guard action?.commentID != nil, action?.decision != nil else {
                return InboxToolbar(buttons: actionLinks, overflow: [])
            }
            return InboxToolbar(buttons: [move(.decide)] + actionLinks, overflow: [.move(.sendToRework)])
        case .clarify:
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
    public static let humanReviewState = "Human Review"
    public static let todoState = "Todo"

    public var move: InboxMove
    /// The Inbox item's issue id.
    public var itemID: String
    public var identifier: String
    public var title: String
    public var happens: String
    public var stays: String
    /// The picks a decisions sheet posts, listed in it.
    public var picks: [ControlAction.DecisionPick]
    /// True when the move answers a decision request instead of moving the ticket on its own.
    public var isDecision: Bool
    /// The request a decision answers, as one decision; nil for the moves that don't answer one.
    public var request: InboxReview.Decision?
    /// The id of the request comment the answer replies under, nil for the moves that don't answer one.
    public var requestCommentID: String?
    /// The state the move is expected to put the ticket in, nil when it stays (decisions on a plan in In Review).
    /// The banner follows Symphony's answer instead, which knows the workflow's states.
    public var targetState: String?

    public var id: String { "\(itemID):\(move.rawValue)" }
    public var verb: String { move.verb }
    /// Send to Rework and Restart use the destructive style.
    public var isDestructive: Bool { move == .sendToRework || move == .restart }
    /// Send to Rework and Restart can't be sent without a reason.
    public var needsReason: Bool { move == .sendToRework || move == .restart }
    /// Why the ticket goes back (Rework), or starts over (Restart).
    public var reasonPrompt: String {
        move == .restart ? "Why does \(identifier) start over?" : "Why does \(identifier) go back?"
    }

    public init(move: InboxMove, item: InboxItem, picks: DecisionPicks = DecisionPicks()) {
        self.move = move
        itemID = item.id
        identifier = item.identifier
        let id = item.identifier
        // An action carrying a request is answered through `decide`, whatever the button: the reply under the
        // request comment is what closes it, and a plain move would leave the hold behind. Without the request
        // comment there is nothing to reply under, so neither button answers one.
        let answersRequest = item.kind == .action && item.review.action?.commentID != nil
        isDecision = (move == .decide || move == .sendToRework) && answersRequest
        request = isDecision ? item.review.action?.decision : nil
        requestCommentID = isDecision ? item.review.action?.commentID : nil
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
            if isDecision {
                happens = "Records your answer on \(id) and moves it to Rework through the guard."
                stays = "Your answer stays on the ticket as the recorded decision, even after Undo."
            } else if item.kind == .plan {
                happens = "Posts your reason on \(id) and moves it to Rework: Symphony cancels the plan's sub-tickets still in Backlog and plans again."
                stays = "Your reason stays on the ticket as your comment, even after Undo."
            } else {
                happens = "Posts your reason on \(id) and moves it to Rework: Symphony continues on the same pull request. Restart instead closes the pull request and starts over from main."
                stays = "Your reason stays on the ticket as your comment, even after Undo."
            }
        case .restart:
            title = "Restart \(id) from main?"
            targetState = "In Progress"
            happens = "Closes \(id)'s open pull request, removes its workspace so the next run branches fresh from main, supersedes the workpad, and moves \(id) to In Progress."
            stays = "The issue and its comments stay, and the previous attempt stays in the workpad under a Superseded heading."
        case .signOff:
            title = "Sign off \(id)?"
            targetState = "Done"
            happens = "Moves \(id) to Done; the parent's close-out run follows."
            stays = "Nothing else changes in Linear."
        case .decide:
            title = "Send your decision on \(id)?"
            self.picks = picks.answers([item.review.action?.decision].compactMap { $0 })
            // A merge confirmation continues into the state its hold names. A request that parked its ticket in
            // Human Review set no hold: answering it moves the ticket to Todo, so the next run carries the decision
            // out. An ordinary decision moves nothing.
            if let confirm = item.review.action?.confirm {
                targetState = confirm
                happens = "Records your answer on \(id) as a reply to its request, clears the `Needs Decision` label and moves \(id) to \(confirm)."
                stays = "Nothing merges while a check is red or pending. Your answer stays on the ticket as the recorded decision."
            } else if item.state?.caseInsensitiveCompare(Self.humanReviewState) == .orderedSame {
                targetState = Self.todoState
                happens = "Records your answer on \(id) as a reply to its request and moves \(id) to \(Self.todoState): the next run carries it out."
                stays = "Your answer stays on the ticket as the recorded decision, even after Undo."
            } else {
                targetState = nil
                happens = "Records your answer on \(id) as a reply to its request and clears the `Needs Decision` label: \(id) continues in \(item.state ?? "its phase")."
                stays = "The ticket doesn't move: the decision is what it was waiting on."
            }
        case .unblock:
            title = "Unblock \(id)?"
            // The ticket keeps its phase: clearing a hold moves nothing, it resumes in place.
            targetState = nil
            happens = "Clears the hold on \(id) and notes it on the ticket; \(id) continues from where it stopped."
            stays = "The ticket keeps its state. Nothing else changes in Linear."
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
        let answer = reason.trimmingWhitespace()
        switch move {
        case .approvePlan: return .approvePlan(identifier)
        case .sendDecisions: return .decisions(identifier, picks: picks)
        case .approveAndMerge: return .approvePR(identifier)
        case .sendToRework:
            guard isDecision, let requestCommentID else { return .rework(identifier, reason: answer) }
            return .decide(
                identifier,
                requestCommentID: requestCommentID,
                picks: [.init(question: request?.question ?? identifier, answer: answer)],
                move: "rework"
            )
        case .restart: return .restart(identifier, reason: answer)
        case .signOff: return .signOff(identifier)
        case .decide:
            guard let requestCommentID else { return nil }
            return .decide(identifier, requestCommentID: requestCommentID, picks: picks, move: nil)
        case .unblock: return .unblock(identifier)
        }
    }

    /// What the sheet expects Symphony to answer, for an answer that didn't say.
    public var expectedOutcome: MoveOutcome { MoveOutcome(moved: targetState != nil, toState: targetState) }

    /// The banner once the move is made (C18), from Symphony's answer: Undo only after the ticket moved.
    /// A restart offers no Undo: it closed the pull request, deleted the workspace and superseded the
    /// workpad, and Symphony can't take any of that back. Unblock moves nothing, so it says what it did
    /// instead of where the ticket went.
    public func banner(after outcome: MoveOutcome) -> InboxBanner {
        if outcome.moved {
            return InboxBanner(
                itemID: itemID,
                identifier: identifier,
                text: "Moved to \(outcome.toState ?? targetState ?? "its next state")",
                undo: move != .restart
            )
        }
        if move == .unblock {
            return InboxBanner(itemID: itemID, identifier: identifier, text: "Hold cleared", undo: false)
        }
        return InboxBanner(itemID: itemID, identifier: identifier, text: move == .decide ? "Sent your decision" : "Sent your decisions", undo: false)
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
