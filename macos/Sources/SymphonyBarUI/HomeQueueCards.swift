import Foundation
import SymphonyBarCore

/// What a slot card's move does from Home (TP-1609): Answer… opens the ticket's question in the Inbox's drawer (or the
/// ticket's page when the read names no record), or unblocks it when its move is Unblock; Message… opens the ticket's
/// page, where the box above the timeline writes to it; Stop is the control call that stops it and frees its slot.
public enum HomeSlotMove: Equatable {
    case answer(issueID: String)
    case openTicket(String)
    case control(ControlAction)
}

/// Home's read drawn with the Gallery's components (TP-1609): a slot's ticket as a `SlotCardModel`, a queue row as a
/// `QueueRowModel`. Times are measured against `reference`, Symphony's own clock.
public enum HomeQueueCards {
    /// The working stages' chart colours, as the ticket page's token bar draws them.
    static let series: [String: DesignTokens.ChartSeries] = ["coding": .series1, "code_review": .series2, "qa": .series3, "merging": .series4]

    /// The card's state: waiting on the person, needing attention, or working.
    public static func status(_ ticket: HomeRead.SlotTicket) -> DesignTokens.Status {
        if ticket.waitsOnYou { return .you }
        if ticket.situation?.kind.status == .problem { return .problem }
        return .working
    }

    /// The stage it is in, 0 (Coding) to 4 (Done): the read's current stage, else the stage marked current or paused.
    public static func stage(_ ticket: HomeRead.SlotTicket) -> Int {
        let ids = SlotCardModel.stageNames.map(\.id)
        let current = ticket.currentStage ?? ticket.stages.first { $0.state == "current" || $0.state == "paused" }?.id
        return current.flatMap { ids.firstIndex(of: $0) } ?? 0
    }

    public static func card(_ ticket: HomeRead.SlotTicket, epic: String? = nil, reference: Date) -> SlotCardModel {
        let since = ticket.since.map { Overview.duration(max(Int(reference.timeIntervalSince($0)), 0)) } ?? "—"
        let tokens = ticket.stages.compactMap { stage in
            series[stage.id].map { TokenLine.Stage(name: stage.name, tokens: stage.tokens, series: $0) }
        }
        return SlotCardModel(
            identifier: ticket.identifier, title: ticket.title ?? ticket.identifier, epic: epic, status: status(ticket), stage: stage(ticket),
            since: since, word: ticket.situation?.word ?? ticket.phase ?? "In progress", sentence: ticket.situation?.cause ?? "",
            tokens: tokens, tokenTotal: ticket.tokens, tokenCap: ticket.tokenBudget, plan: ticket.plan ?? noPlan,
            proved: ticket.checks?.proved ?? 0, checks: ticket.checks?.total ?? 0, next: ticket.checks?.next,
            pullRequest: ticket.pullRequest.flatMap(pullRequest)
        )
    }

    /// The Plan column of a ticket with no plan yet.
    public static let noPlan = "No plan yet."

    static func pullRequest(_ pull: HomeRead.PullRequest) -> SlotCardModel.PullRequest? {
        guard let number = pull.number else { return nil }
        var size: [String] = []
        if let files = pull.filesChanged { size.append(files == 1 ? "1 file" : "\(DesignTokens.HomeQueue.number(files)) files") }
        if let additions = pull.additions, let deletions = pull.deletions {
            size.append("+\(DesignTokens.HomeQueue.number(additions)) −\(DesignTokens.HomeQueue.number(deletions))")
        }
        return SlotCardModel.PullRequest(
            number: "#\(number)", size: size.joined(separator: " · "), branch: pull.branch ?? "", ci: ci(pull.ci), review: review(pull.reviewState)
        )
    }

    static func ci(_ state: String?) -> SlotCardModel.Fact {
        switch state {
        case "failed": .init(.problem, "Checks failed")
        case "running": .init(.working, "Checks running")
        case "passed": .init(.done, "Checks passed")
        default: .init(.idle, "No checks yet")
        }
    }

    static func review(_ state: String?) -> SlotCardModel.Fact {
        switch state?.uppercased() {
        case "APPROVED": .init(.done, "Approved")
        case "CHANGES_REQUESTED": .init(.problem, "Changes requested")
        default: .init(.idle, "Not reviewed yet")
        }
    }

    /// The row of the queue at its real number: a whole number as a number, a sub-ticket's "6.1" as the read writes it,
    /// one step in per point (TP-1645). An epic's row has its fold from `fold` and its done count, and no state badge; a
    /// row carries a marker for each dependency it still waits for.
    public static func row(_ row: HomeRead.Row, fold: HomeQueueFold = HomeQueueFold()) -> QueueRowModel {
        let whole = Int(row.number)
        var marks: [QueueRowModel.Mark] = []
        if row.waitsOnYou {
            marks.append(.init(.you, row.situation?.word ?? DesignTokens.Status.you.word))
        } else if !row.isEpic, let phase = row.phase, !["todo", "backlog"].contains(phase.lowercased()) {
            marks.append(.init(.idle, phase))
        }
        let lead: RowLead = row.situation.map { .status($0.kind.status) } ?? .glyph("clock", DesignTokens.TextColor.secondary)
        let epic = row.subTickets.flatMap { counts in
            row.isEpic
                ? QueueRowModel.Epic(
                    done: counts.done, total: counts.total, open: fold.isOpen(row.identifier), showingDone: fold.showsDone(row.identifier)
                )
                : nil
        }
        return QueueRowModel(
            number: whole ?? Int(row.number.split(separator: ".").first ?? "") ?? 0, identifier: row.identifier,
            title: row.title ?? row.identifier, lead: lead, dependencies: row.unmet.map(dependency), marks: marks, repo: row.repoKey ?? "",
            label: whole == nil ? row.number : nil, epic: epic, depth: row.number.filter { $0 == "." }.count
        )
    }

    /// A slot's epic as its epic slot card draws it (TP-1646): its time in the slot against `reference`, its done
    /// sub-tickets oldest first with the pull request and when (in `timeZone`), and its open ones in queue order, each
    /// numbered on from the done count (with 7 done the first to come is 9), with a marker for each dependency it still
    /// waits for.
    public static func epicCard(_ epic: HomeRead.SlotEpic, reference: Date, timeZone: TimeZone = .current) -> EpicSlotCardModel {
        let since = epic.since.map { Overview.duration(max(Int(reference.timeIntervalSince($0)), 0)) } ?? "—"
        return EpicSlotCardModel(
            identifier: epic.identifier, title: epic.title ?? epic.identifier, done: epic.done, total: epic.total, since: since,
            doneRows: epic.doneSubTickets.map { done($0, epic: epic.identifier, reference: reference, timeZone: timeZone) },
            upcoming: epic.openSubTickets.enumerated().map { index, row in upcoming(row, number: epic.number(at: index)) }
        )
    }

    /// An epic slot card's row to come: the queue row of the sub-ticket at the top level of the card's list, at `number`.
    public static func upcoming(_ row: HomeRead.Row, number: Int) -> QueueRowModel {
        var model = self.row(row)
        model.number = number
        model.label = nil
        model.depth = 0
        return model
    }

    /// A dependency's marker: the ticket waited for, done or released.
    public static func dependency(_ dependency: HomeRead.Dependency) -> DependencyMarkerModel {
        DependencyMarkerModel(identifier: dependency.identifier, kind: dependency.kind == .released ? .released : .done)
    }

    /// An epic's done sub-ticket as a quiet done row of the queue (TP-1645): when it was done against `reference` in
    /// `timeZone`, the only cell the queue shows.
    public static func done(_ ticket: HomeRead.DoneSubTicket, epic: String, reference: Date, timeZone: TimeZone = .current) -> DoneRowModel {
        DoneRowModel(
            identifier: ticket.identifier, title: ticket.title ?? ticket.identifier, epic: epic,
            pullRequest: ticket.pullRequestNumber.map { "#\($0)" }, repo: "", when: DoneWhen.text(ticket.doneAt, now: reference, timeZone: timeZone)
        )
    }

    /// A Recently done entry as a done row (TP-1644): its epic, its pull request as "#1053", its repo, and when it was
    /// done against `reference` in `timeZone`.
    public static func done(_ entry: HomeRead.DoneEntry, reference: Date, timeZone: TimeZone = .current) -> DoneRowModel {
        DoneRowModel(
            identifier: entry.identifier, title: entry.title ?? entry.identifier, epic: entry.epic?.identifier,
            pullRequest: entry.pullRequestNumber.map { "#\($0)" }, repo: entry.repoKey ?? "",
            when: DoneWhen.text(entry.doneAt, now: reference, timeZone: timeZone)
        )
    }

    /// What a card's move does for `ticket`.
    public static func move(_ action: SlotCardModel.Action, _ ticket: HomeRead.SlotTicket) -> HomeSlotMove {
        switch action {
        case .answer:
            if ticket.move?.name == "unblock" { return .control(.unblock(ticket.identifier)) }
            return ticket.issueID.map { .answer(issueID: $0) } ?? .openTicket(ticket.identifier)
        case .message:
            return .openTicket(ticket.identifier)
        case .stop:
            return .control(.stop(ticket.identifier))
        }
    }
}
