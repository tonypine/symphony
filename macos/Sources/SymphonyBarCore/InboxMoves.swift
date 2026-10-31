import Foundation

/// A move the Director makes on an Inbox item (US2). Each opens its consequence sheet first (C17, P5, D12d); nothing
/// changes Linear until the sheet's button is pressed.
public enum InboxMove: String, CaseIterable, Equatable, Identifiable {
    case approvePlan
    /// Answers a plan's questions: each answer goes under its question, and Symphony revises the plan from them.
    case sendDecisions
    /// Asks for changes to a plan: Symphony revises it in place and keeps its sub-tickets.
    case askForChanges
    /// Rejects a plan: Symphony cancels its sub-tickets still in Backlog and plans again.
    case rejectPlan
    case approveAndMerge
    case sendToRework
    case restart
    /// Answers a decision request: the ticket continues in its phase, or the answer directs a move.
    case decide
    case unblock
    /// Releases a pause the Director may lift (a ticket it waits on, an environment hold): it sends the unblock move.
    case release

    public var id: String { rawValue }

    /// The toolbar button: "…" where a sheet asks more.
    public var buttonTitle: String {
        switch self {
        case .approvePlan: "Approve Plan…"
        case .sendDecisions: "Send Decisions"
        case .askForChanges: "Ask for Changes…"
        case .rejectPlan: "Reject Plan…"
        case .approveAndMerge: "Approve and Merge…"
        case .sendToRework: "Send to Rework…"
        case .restart: "Restart…"
        case .decide: "Send Decision…"
        case .unblock: "Unblock…"
        case .release: "Release…"
        }
    }

    /// The sheet's action button, named with its verb.
    public var verb: String {
        switch self {
        case .approvePlan: "Approve Plan"
        case .sendDecisions: "Send Decisions"
        case .askForChanges: "Ask for Changes"
        case .rejectPlan: "Reject Plan"
        case .approveAndMerge: "Approve and Merge"
        case .sendToRework: "Send to Rework"
        case .restart: "Restart"
        case .decide: "Send Decision"
        case .unblock: "Unblock"
        case .release: "Release"
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

    /// The toolbar of `item`: a plan with open questions offers Send Decisions first (on once every question has an
    /// answer), then Approve Plan… and Ask for Changes…, with ⋯ Reject Plan… and Restart…; one without questions
    /// Approve Plan… first. Answering and asking for changes keep the plan's sub-tickets; only Reject Plan cancels
    /// them. A PR waiting on its merge confirmation Approve and Merge…
    /// and Send to Rework…, which answer the request, with Open PR the default while a check is red (D2b), and
    /// ⋯ Restart…; a PR with no request to answer only its links and ⋯ Restart…; a blocked ticket
    /// Unblock… and ⋯ Restart…, which also lifts a dispatch-loop hold, or Release… in place of Unblock… when its
    /// pause has a reason the Director may release and no stop of theirs. Actions and clarify items keep their links.
    /// Restart (the human-only full reset) sits under ⋯ on all three, so it takes a deliberate trip through the menu
    /// and its consequence sheet. An action carrying an
    /// answerable decision offers Send Decision…, with ⋯ Send to Rework… answering it as a redirect; another action,
    /// and a clarify item, keep their links, but an action whose options are listed in its card drops the Copy Steps
    /// link that would only repeat them.
    public static func toolbar(for item: InboxItem, picks: DecisionPicks = DecisionPicks()) -> InboxToolbar {
        let links = InboxAction.actions(for: item).map { Button(command: .link($0), enabled: true) }
        func move(_ move: InboxMove, enabled: Bool = true) -> Button { Button(command: .move(move), enabled: enabled) }
        let restart: [InboxCommand] = [.move(.restart)]
        switch item.kind {
        case .plan:
            let questions = item.review.questions
            let moves = questions.isEmpty
                ? [move(.approvePlan), move(.askForChanges)]
                : [move(.sendDecisions, enabled: picks.answersAll(questions)), move(.approvePlan), move(.askForChanges)]
            return InboxToolbar(buttons: moves + links, overflow: [.move(.rejectPlan)] + restart)
        case .pr:
            // Symphony has no move of its own for a PR: it reaches the Inbox on its merge confirmation, a decision
            // request, and both moves answer that request through `decide`.
            guard item.review.action?.answered != nil, item.review.action?.confirmingOption != nil else {
                return InboxToolbar(buttons: links, overflow: restart)
            }
            let moves = [move(.approveAndMerge), move(.sendToRework)]
            if item.review.pullRequest?.hasRedCheck == true, let openPR = links.first, case .link(.openPR) = openPR.command {
                return InboxToolbar(buttons: [openPR] + moves + links.dropFirst(), overflow: restart)
            }
            return InboxToolbar(buttons: moves + links, overflow: restart)
        case .blocked:
            let lift = item.review.blocked?.releasable == true ? InboxMove.release : .unblock
            return InboxToolbar(buttons: [move(lift)] + links, overflow: restart)
        case .action:
            let action = item.review.action
            // A request's options are shown and picked in its card, so its Copy Steps link (which would list the
            // same options) is left out; a steps-only action keeps it.
            let actionLinks = links.filter { button in
                if case .link(.copySteps) = button.command, action?.options.isEmpty == false { return false }
                return true
            }
            guard let action, action.answered != nil, action.decision != nil else {
                return InboxToolbar(buttons: actionLinks, overflow: [])
            }
            // The write-in picked with nothing in it has no answer to send.
            let blankWriteIn = action.isWriteIn(picks) && action.answer(picks) == nil
            return InboxToolbar(buttons: [move(.decide, enabled: !blankWriteIn)] + actionLinks, overflow: [.move(.sendToRework)])
        case .clarify:
            return InboxToolbar(buttons: links, overflow: [])
        }
    }
}

extension InboxReview.Action {
    /// The option that confirms the request: the one whose effect moves the ticket to the state its hold carries
    /// (a merge confirmation's Merge), as Symphony reads a pick. Nil for an ordinary decision, which carries none.
    public var confirmingOption: Option? {
        guard let confirm else { return nil }
        return options.first { $0.effect?.localizedCaseInsensitiveContains("moves to \(confirm)") == true }
    }

    /// The index of the option Send Decision sends: the Director's pick, else the recommended one; `writeInIndex`
    /// for the write-in; nil when none is picked.
    public func pickedIndex(_ picks: DecisionPicks) -> Int? {
        guard let decision, let index = picks.pick(0, in: decision), options.indices.contains(index) || index == writeInIndex else {
            return nil
        }
        return index
    }

    /// The option Send Decision sends, nil when none is picked or the write-in is.
    public func pickedOption(_ picks: DecisionPicks) -> Option? {
        pickedIndex(picks).flatMap { options.indices.contains($0) ? options[$0] : nil }
    }

    /// True when the write-in (N11) is picked: Send Decision sends the Director's own words.
    public func isWriteIn(_ picks: DecisionPicks) -> Bool {
        pickedIndex(picks) == writeInIndex
    }

    /// What Send Decision posts: the question with the picked option's label, or with the Director's own words when
    /// the write-in is picked; nil when nothing is picked, or the write-in is blank.
    public func answer(_ picks: DecisionPicks) -> ControlAction.DecisionPick? {
        guard let index = pickedIndex(picks) else { return nil }
        let text = index == writeInIndex ? picks.writeIn.trimmingWhitespace() : options[index].label
        return text.isEmpty ? nil : ControlAction.DecisionPick(question: question ?? "", answer: text)
    }
}

extension InboxItem {
    /// True when the item carries a request the Inbox answers: its options are picked, and Send Decision sends one.
    public var answerable: Bool { review.action?.answered != nil && review.action?.decision != nil }

    /// The option a number key picks in the item's request; nil for another key, or a request the Inbox doesn't
    /// answer.
    public func optionIndex(forKey key: Character) -> Int? {
        guard kind == .action, answerable else { return nil }
        return review.action?.optionIndex(forKey: key)
    }
}

extension InboxReview {
    /// A plan's questions as decisions (C16), in the same order, so the picks answer them by index.
    public var decisions: [Decision] {
        questions.map { $0.decision ?? Decision(question: $0.question ?? "", options: [], recommendation: nil, recommended: nil) }
    }
}

/// The Director's picks in a request's or a plan's decisions (C16), by decision index; a decision not picked keeps its
/// recommended option.
public struct DecisionPicks: Equatable {
    public var picks: [Int: Int]
    /// What the Director wrote in each decision's write-in (N11), by decision index, kept with the picks while they
    /// look at other items.
    public var writeIns: [Int: String]

    public init(picks: [Int: Int] = [:], writeIn: String = "", writeIns: [Int: String] = [:]) {
        self.picks = picks
        self.writeIns = writeIns
        if !writeIn.isEmpty { self.writeIns[0] = writeIn }
    }

    /// The write-in of a request's one decision.
    public var writeIn: String {
        get { writeIns[0] ?? "" }
        set { writeIns[0] = newValue }
    }

    /// The option shown picked in decision `index`: the Director's pick, else the recommended one.
    public func pick(_ index: Int, in decision: InboxReview.Decision) -> Int? {
        picks[index] ?? decision.initialPick
    }

    /// The answer to a plan's question `index`: its picked option's label, or the Director's own words when its
    /// write-in is picked, with the request it answers; nil when nothing is picked or the write-in is blank.
    public func answer(_ index: Int, of question: InboxReview.Action) -> ControlAction.DecisionPick? {
        guard let decision = question.decision, let pick = pick(index, in: decision) else { return nil }
        let text = pick == question.writeInIndex ? (writeIns[index] ?? "").trimmingWhitespace() : (question.options.indices.contains(pick) ? question.options[pick].label : "")
        return text.isEmpty ? nil : ControlAction.DecisionPick(question: decision.question, answer: text, requestCommentID: question.commentID)
    }

    /// Each of a plan's questions with its answer, as Send Decisions posts them; a question with no answer is left
    /// out.
    public func answers(_ questions: [InboxReview.Action]) -> [ControlAction.DecisionPick] {
        questions.enumerated().compactMap { answer($0.offset, of: $0.element) }
    }

    /// True when every one of a plan's questions has an answer: Send Decisions turns on.
    public func answersAll(_ questions: [InboxReview.Action]) -> Bool {
        !questions.isEmpty && answers(questions).count == questions.count
    }
}

/// The Director's picks and write-ins across the Inbox, by issue id: each item keeps its own while the Director looks
/// at other items, until its answer is sent.
public struct InboxPicks: Equatable {
    private var byItem: [String: DecisionPicks] = [:]

    public init() {}

    /// The picks of the item with issue id `itemID`; an item not touched yet has none.
    public subscript(itemID: String) -> DecisionPicks { byItem[itemID] ?? DecisionPicks() }

    /// Picks option `option` in decision `decision` of the item.
    public mutating func pick(_ option: Int, decision: Int, itemID: String) {
        byItem[itemID, default: DecisionPicks()].picks[decision] = option
    }

    /// Keeps the words written in the write-in (N11) of decision `decision` of the item. Returns true when they turned
    /// blank or stopped being blank, the one change Send Decision… shows; the field shows the words themselves.
    @discardableResult
    public mutating func writeIn(_ text: String, itemID: String, decision: Int = 0) -> Bool {
        let wasBlank = (self[itemID].writeIns[decision] ?? "").trimmingWhitespace().isEmpty
        byItem[itemID, default: DecisionPicks()].writeIns[decision] = text
        return wasBlank != text.trimmingWhitespace().isEmpty
    }

    /// Forgets the item's picks once they were sent.
    public mutating func clear(_ itemID: String) {
        byItem[itemID] = nil
    }
}

/// How far each Inbox review is scrolled, by issue id: a page opened from the review (D3, D15) and left with ⌘[ finds
/// the review where it was, as the peek (N4) does.
public struct InboxScrollOffsets: Equatable {
    private var byItem: [String: Double] = [:]

    public init() {}

    /// The review's offset from its top in points; nil for a review not scrolled yet.
    public subscript(itemID: String) -> Double? {
        get { byItem[itemID] }
        set { byItem[itemID] = newValue.flatMap { $0 > 0 ? $0 : nil } }
    }

    /// A review's offset from its top, from its scroll view's content offset, which counts from under the window's
    /// toolbar (−52 at the top): the offset `ScrollPosition.scrollTo(y:)` takes.
    public static func fromTop(contentOffset: Double, topInset: Double) -> Double {
        contentOffset + topInset
    }
}

/// The consequence sheet of a move (C17, P5, D12d): the question as its title, what happens in Linear, what stays
/// the same, the options (Rework's required reason), and Cancel with the verb.
public struct ConsequenceSheet: Equatable, Identifiable {
    public static let waitingState = "Waiting on sub-tickets"

    public var move: InboxMove
    /// The Inbox item's issue id.
    public var itemID: String
    public var identifier: String
    public var title: String
    public var happens: String
    public var stays: String
    /// The picks a decisions sheet posts, listed in it.
    public var picks: [ControlAction.DecisionPick]
    /// True when Send Decision sends the Director's own words (N11) instead of an option.
    public var isWriteIn: Bool
    /// Those words, quoted in the sheet; nil while the write-in is blank, and for every other sheet.
    public var quote: String?
    /// True when the move answers a decision request instead of moving the ticket on its own.
    public var isDecision: Bool
    /// The request a decision answers, as one decision; nil for the moves that don't answer one.
    public var request: InboxReview.Decision?
    /// The request the answer names (its Question, else its request comment), nil for the moves that don't answer
    /// one.
    public var answeredRequest: ControlAction.AnsweredRequest?
    /// The state the move is expected to put the ticket in, nil when it stays (decisions on a plan in Plan Review).
    /// The banner follows Symphony's answer instead, which knows the workflow's states.
    public var targetState: String?

    public var id: String { "\(itemID):\(move.rawValue)" }
    public var verb: String { move.verb }
    /// Whether the sheet lists the picks it posts: Send Decision names its one pick in the title instead.
    public var listsPicks: Bool { !picks.isEmpty && move != .decide }
    /// Send to Rework, Reject Plan and Restart use the destructive style.
    public var isDestructive: Bool { [.sendToRework, .rejectPlan, .restart].contains(move) }
    /// Send to Rework, Ask for Changes, Reject Plan and Restart can't be sent without a reason.
    public var needsReason: Bool { [.sendToRework, .askForChanges, .rejectPlan, .restart].contains(move) }
    /// Why the ticket goes back (Rework), starts over (Restart), what should change in a plan, or why it is rejected.
    public var reasonPrompt: String {
        switch move {
        case .restart: "Why does \(identifier) start over?"
        case .askForChanges: "What should change in the plan of \(identifier)?"
        case .rejectPlan: "Why is the plan of \(identifier) rejected?"
        default: "Why does \(identifier) go back?"
        }
    }

    public init(move: InboxMove, item: InboxItem, picks: DecisionPicks = DecisionPicks()) {
        self.move = move
        itemID = item.id
        identifier = item.identifier
        let id = item.identifier
        // An action or a PR carrying a request is answered through `decide`, whatever the button: the answer to its
        // Question is what closes it, and a plain move would leave the hold behind. Without the Question's id or the
        // request comment there is nothing to answer, so no button answers one.
        let answersRequest = [.action, .pr].contains(item.kind) && item.review.action?.answered != nil
        isDecision = [.decide, .sendToRework, .approveAndMerge].contains(move) && answersRequest
        request = isDecision ? item.review.action?.decision : nil
        answeredRequest = isDecision ? item.review.action?.answered : nil
        self.picks = []
        isWriteIn = false
        quote = nil
        switch move {
        case .approvePlan:
            title = "Approve the plan of \(id)?"
            targetState = Self.waitingState
            happens = "Moves \(id) to \(Self.waitingState)" + Self.promotion(item.review.subTickets) + "."
            let open = item.review.questions.count
            if let unapplied = item.review.unappliedAnswersWarning {
                stays = "\(unapplied) Approving now approves the plan as written, without \(item.review.unappliedAnswers == 1 ? "it" : "them")."
            } else {
                stays = open == 0
                    ? "The plan stays as written. To change it, ask for changes instead."
                    : "The plan stays as written: \(open == 1 ? "its open question is" : "its \(open) open questions are") not answered. To have Symphony apply your answers first, choose Send Decisions instead."
            }
        case .sendDecisions:
            title = "Send your answers on \(id)?"
            // Symphony moves a plan under review to Rework to revise it, and an approved plan stays: its answer says
            // which, so the sheet guesses no state and the app holds the answers for Undo before sending them.
            targetState = nil
            self.picks = picks.answers(item.review.questions)
            happens = "Records each answer under its question on \(id) and moves it to Rework, where Symphony revises the plan from them. The plan keeps its sub-tickets."
            stays = "The plan isn't approved: it comes back to \(item.state ?? "Plan Review") once Symphony has revised it, and you approve it then."
        case .askForChanges:
            title = "Ask for changes to the plan of \(id)?"
            targetState = nil
            happens = "Posts your request on \(id) and moves it to Rework, where Symphony revises the plan from it. The plan keeps its sub-tickets."
            stays = "The plan isn't approved: it comes back to \(item.state ?? "Plan Review") once Symphony has revised it."
        case .rejectPlan:
            title = "Reject the plan of \(id)?"
            targetState = "Rework"
            happens = "Posts your reason on \(id) and moves it to Rework: Symphony cancels " + Self.cancellation(item.review.subTickets) + " and plans again."
            stays = "Sub-tickets already started are kept. Your reason stays on the ticket as your comment, even after Undo."
        case .approveAndMerge:
            // Confirming picks the request's option that moves the ticket to the state its hold carries, so
            // Symphony continues it there exactly as with manual review off.
            let confirm = item.review.action?.confirm ?? "Merging"
            title = "Move \(id) to \(confirm)?"
            targetState = confirm
            if let request, let option = item.review.action?.confirmingOption {
                self.picks = [.init(question: request.question.isEmpty ? id : request.question, answer: option.label)]
            }
            happens = "Records your answer on \(id) as a reply to its merge request, clears the Needs Decision label and moves \(id) to \(confirm): Symphony turns on auto-merge, and GitHub merges the pull request once checks pass."
            stays = "Nothing merges while a check is red or pending, and the diff stays on GitHub."
        case .sendToRework:
            title = "Send \(id) to Rework?"
            targetState = "Rework"
            if isDecision {
                happens = "Records your answer on \(id) and moves it to Rework through the guard."
                stays = "Your answer stays on the ticket as the recorded decision, even after Undo."
            } else {
                happens = "Posts your reason on \(id) and moves it to Rework: Symphony continues on the same pull request. Restart instead closes the pull request and starts over from main."
                stays = "Your reason stays on the ticket as your comment, even after Undo."
            }
        case .restart:
            title = "Restart \(id) from main?"
            targetState = "In Progress"
            happens = "Closes \(id)'s open pull request, removes its workspace so the next run branches fresh from main, supersedes the workpad, and moves \(id) to In Progress."
            stays = "The issue and its comments stay, and the previous attempt stays in the workpad under a Superseded heading."
        case .decide:
            // The sheet names the pick and what it does (D12d): `Send "Leave it to TP-891"?` and the option's effect.
            // A write-in (N11) asks "Send your answer?" and quotes the Director's words.
            let action = item.review.action
            let picked = action?.pickedOption(picks)
            let writeIn = action?.isWriteIn(picks) == true
            isWriteIn = writeIn
            title = writeIn ? "Send your answer?" : picked.map { "Send \"\($0.label)\"?" } ?? "Send your decision on \(id)?"
            self.picks = [action?.answer(picks)].compactMap { $0 }
            quote = writeIn ? self.picks.first?.answer : nil
            if action?.confirm != nil, writeIn {
                // Words that pick none of a confirmation's options ask for a change: Symphony moves the ticket to
                // In Progress, where its next run takes them up on the same pull request.
                targetState = "In Progress"
                happens = "Records your answer on \(id) as a reply to its request, clears the Needs Decision label and moves \(id) to In Progress, where its next run takes up your answer."
                stays = "Nothing merges, and the pull request stays open."
            } else if let confirm = action?.confirm {
                // A merge confirmation continues into the state its hold names. An ordinary decision moves nothing.
                targetState = confirm
                happens = "Records your answer on \(id) as a reply to its request, clears the Needs Decision label and moves \(id) to \(confirm)."
                stays = "Nothing merges while a check is red or pending. Your answer stays on the ticket as the recorded decision."
            } else {
                targetState = nil
                happens = picked?.effect
                    ?? "Records your answer on \(id) as a reply to its request and clears the Needs Decision label."
                stays = "\(id) stays in \(item.state ?? "its phase") until its next run picks up your answer."
            }
        case .unblock:
            title = "Unblock \(id)?"
            // The ticket keeps its phase: clearing a hold moves nothing, it resumes in place.
            targetState = nil
            happens = "Clears the hold on \(id) and notes it on the ticket; \(id) continues from where it stopped."
            stays = "The ticket keeps its state. Nothing else changes in Linear."
        case .release:
            title = "Release \(id)?"
            targetState = nil
            let waits = item.review.blocked?.pauseReasons.filter(\.releasable).map(\.text) ?? []
            happens = "Releases the pause on \(id)" + (waits.isEmpty ? "" : " (\(waits.joined(separator: "; ")))")
                + " and notes it on the ticket; \(id) continues from where it stopped."
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

    /// "its 3 sub-tickets still in Backlog (SHOP-331, SHOP-332, SHOP-333)", or "no sub-ticket, since none is still in
    /// Backlog".
    static func cancellation(_ tickets: [InboxReview.SubTicket]) -> String {
        let backlog = tickets.filter { ($0.state ?? "Backlog").caseInsensitiveCompare("Backlog") == .orderedSame }
        guard !backlog.isEmpty else { return "no sub-ticket, since none is still in Backlog," }
        let count = backlog.count == 1 ? "its sub-ticket" : "its \(backlog.count) sub-tickets"
        return "\(count) still in Backlog (\(backlog.map(\.identifier).joined(separator: ", ")))"
    }

    /// Whether the sheet's button is on for `reason`; a blank write-in has nothing to send.
    public func canSend(reason: String) -> Bool {
        (!isWriteIn || quote != nil) && (!needsReason || !reason.trimmingWhitespace().isEmpty)
    }

    /// The control request the sheet's button sends, nil while a required reason is missing.
    public func action(reason: String = "") -> ControlAction? {
        guard canSend(reason: reason) else { return nil }
        let answer = reason.trimmingWhitespace()
        switch move {
        case .approvePlan: return .approvePlan(identifier)
        case .sendDecisions: return .decisions(identifier, picks: picks)
        case .askForChanges: return .changes(identifier, reason: answer)
        case .rejectPlan: return .rework(identifier, reason: answer)
        case .approveAndMerge:
            guard let answeredRequest, !picks.isEmpty else { return nil }
            return .decide(identifier, request: answeredRequest, picks: picks, move: nil)
        case .sendToRework:
            guard isDecision, let answeredRequest else { return .rework(identifier, reason: answer) }
            return .decide(
                identifier,
                request: answeredRequest,
                picks: [.init(question: request?.question ?? identifier, answer: answer)],
                move: "rework"
            )
        case .restart: return .restart(identifier, reason: answer)
        case .decide:
            guard let answeredRequest else { return nil }
            return .decide(identifier, request: answeredRequest, picks: picks, move: nil)
        case .unblock, .release: return .unblock(identifier)
        }
    }

    /// What the sheet expects Symphony to answer, for an answer that didn't say.
    public var expectedOutcome: MoveOutcome { MoveOutcome(moved: targetState != nil, toState: targetState) }

    /// Whether the Inbox selects the next item once the move is made (P4): after the ticket moved, or after a
    /// request was answered, which leaves the Inbox with the next poll even when the ticket stays in its phase.
    public func selectsNext(after outcome: MoveOutcome) -> Bool { outcome.moved || isDecision }

    /// Whether the app holds the request for `InboxBanner.duration` before it sends it, with Undo on the banner
    /// (DS10). An answer that leaves the ticket in place has no move for Symphony's Undo to take back, and once
    /// Symphony posted it and cleared the hold the next run is on its way, so the answer waits in the app and Undo
    /// keeps it from ever reaching Linear. An answer that moves the ticket (a merge confirmation) is sent at once:
    /// its move is undone as any other.
    public var holdsForUndo: Bool { [.decide, .sendDecisions, .askForChanges].contains(move) && targetState == nil }

    /// What the banners call what an in-place move sends.
    private var sent: String {
        switch move {
        case .decide: "your decision"
        case .askForChanges: "your changes"
        default: "your decisions"
        }
    }

    /// The banner while the app holds the answer (`holdsForUndo`): its Undo takes the answer back before it is sent.
    public var heldBanner: InboxBanner {
        InboxBanner(itemID: itemID, identifier: identifier, text: "Sending \(sent)", undo: true)
    }

    /// The banner once the move is made (C18), from Symphony's answer: Undo only after the ticket moved.
    /// A restart offers no Undo: it closed the pull request, deleted the workspace and superseded the
    /// workpad, and Symphony can't take any of that back. Unblock moves nothing, so it says what it did
    /// instead of where the ticket went.
    public func banner(after outcome: MoveOutcome) -> InboxBanner {
        // Answers or changes that started the plan's revision were held for Undo before they were sent: once Symphony
        // moved the plan to revise it, there is nothing left to take back.
        if outcome.moved, [.sendDecisions, .askForChanges].contains(move) {
            return InboxBanner(itemID: itemID, identifier: identifier, text: "Sent \(sent): revising the plan in \(outcome.toState ?? "Rework")", undo: false)
        }
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
        if move == .release {
            return InboxBanner(itemID: itemID, identifier: identifier, text: "Released", undo: false)
        }
        return InboxBanner(itemID: itemID, identifier: identifier, text: "Sent \(sent)", undo: false)
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

    /// The banner after Undo took back an answer the app still held: nothing was sent, and the picks stay.
    public static func unsent(itemID: String, identifier: String) -> InboxBanner {
        InboxBanner(itemID: itemID, identifier: identifier, text: "Not sent; your pick is kept", undo: false, style: .info)
    }

    /// The banner for a request that failed, with Symphony's message.
    public static func failed(itemID: String, identifier: String, message: String) -> InboxBanner {
        InboxBanner(itemID: itemID, identifier: identifier, text: message, undo: false, style: .error)
    }

    public static func == (lhs: InboxBanner, rhs: InboxBanner) -> Bool {
        (lhs.itemID, lhs.identifier, lhs.text, lhs.undo, lhs.style) == (rhs.itemID, rhs.identifier, rhs.text, rhs.undo, rhs.style)
    }
}
