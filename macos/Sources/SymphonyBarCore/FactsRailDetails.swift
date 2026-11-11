import Foundation

// The ticket read's `ticket`, `note`, `brief`, `workspace`, `repo_key` and `moves.note` (`docs/control-api.md`
// § `ticket`, § Marks, § `brief`, § `moves`), the ticket's decisions (`GET /api/v1/tickets/:identifier/decisions`) and
// each run's model from its events feed, and what the facts rail's Note for the next run, Decisions and Details panels
// say from them (`docs/design/director-ticket-page.md` §1 facts 17, 18, 22 to 25, 27, 30 and 33).

/// The ticket as its record holds it: its title, phase, Linear priority and labels.
public struct TicketRecordRead: Equatable, Decodable {
    public var title: String?
    public var phase: String?
    /// Linear's: 0 none, 1 urgent, 2 high, 3 medium, 4 low; nil when unknown.
    public var priority: Int?
    public var labels: [String]

    public init(title: String? = nil, phase: String? = nil, priority: Int? = nil, labels: [String] = []) {
        self.title = title
        self.phase = phase
        self.priority = priority
        self.labels = labels
    }

    private enum CodingKeys: String, CodingKey { case title, phase, priority, labels }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        phase = try container.decodeIfPresent(String.self, forKey: .phase)
        priority = try container.decodeIfPresent(Int.self, forKey: .priority)
        labels = try container.decodeIfPresent([String].self, forKey: .labels) ?? []
    }
}

/// The note for the next run: the newest note a person left, and the first run that read it.
public struct TicketNoteRead: Equatable, Decodable {
    public struct ReadBy: Equatable, Decodable {
        public var runID: String
        public var at: Date?

        public init(runID: String, at: Date? = nil) {
            self.runID = runID
            self.at = at
        }

        private enum CodingKeys: String, CodingKey {
            case at
            case runID = "run_id"
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            runID = try container.decode(String.self, forKey: .runID)
            at = try container.decodeIfPresent(String.self, forKey: .at).flatMap(SymphonyState.parseDate)
        }
    }

    public var id: String?
    public var text: String
    public var at: Date?
    /// Who set it, by name.
    public var by: String?
    /// Nil until a run read it.
    public var readBy: ReadBy?

    public init(id: String? = nil, text: String, at: Date? = nil, by: String? = nil, readBy: ReadBy? = nil) {
        self.id = id
        self.text = text
        self.at = at
        self.by = by
        self.readBy = readBy
    }

    private enum CodingKeys: String, CodingKey {
        case id, text, at, by
        case readBy = "read_by"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        at = try container.decodeIfPresent(String.self, forKey: .at).flatMap(SymphonyState.parseDate)
        by = try container.decodeIfPresent(String.self, forKey: .by)
        readBy = try container.decodeIfPresent(ReadBy.self, forKey: .readBy)
    }
}

/// What the ticket does and why, in a person's words, with its walkthrough: written by the implementation run.
public struct TicketBriefRead: Equatable, Decodable {
    public var text: String
    public var walkthrough: String?
    public var at: Date?

    public init(text: String, walkthrough: String? = nil, at: Date? = nil) {
        self.text = text
        self.walkthrough = walkthrough
        self.at = at
    }

    private enum CodingKeys: String, CodingKey { case text, walkthrough, at }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        walkthrough = try container.decodeIfPresent(String.self, forKey: .walkthrough)
        at = try container.decodeIfPresent(String.self, forKey: .at).flatMap(SymphonyState.parseDate)
    }
}

/// Where the ticket's runs work: the folder, and the machine when it is not this one.
public struct TicketWorkspaceRead: Equatable, Decodable {
    public var path: String
    public var host: String?

    public init(path: String, host: String? = nil) {
        self.path = path
        self.host = host
    }
}

/// The ticket read's facts the Note and Details panels say, each nil when the read holds none.
public struct TicketDetailsRead: Equatable, Decodable {
    public var repoKey: String?
    public var ticket: TicketRecordRead?
    public var note: TicketNoteRead?
    public var brief: TicketBriefRead?
    public var workspace: TicketWorkspaceRead?
    /// `moves.note`: whether a note may be written now.
    public var noteMove: TicketMoveRead?

    public init(
        repoKey: String? = nil, ticket: TicketRecordRead? = nil, note: TicketNoteRead? = nil, brief: TicketBriefRead? = nil,
        workspace: TicketWorkspaceRead? = nil, noteMove: TicketMoveRead? = nil
    ) {
        self.repoKey = repoKey
        self.ticket = ticket
        self.note = note
        self.brief = brief
        self.workspace = workspace
        self.noteMove = noteMove
    }

    private enum CodingKeys: String, CodingKey {
        case ticket, note, brief, workspace, moves
        case repoKey = "repo_key"
    }

    private enum MoveKeys: String, CodingKey { case note }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        repoKey = try container.decodeIfPresent(String.self, forKey: .repoKey)
        ticket = try container.decodeIfPresent(TicketRecordRead.self, forKey: .ticket)
        note = try container.decodeIfPresent(TicketNoteRead.self, forKey: .note)
        brief = try container.decodeIfPresent(TicketBriefRead.self, forKey: .brief)
        workspace = try container.decodeIfPresent(TicketWorkspaceRead.self, forKey: .workspace)
        let moves = try? container.nestedContainer(keyedBy: MoveKeys.self, forKey: .moves)
        noteMove = try moves?.decodeIfPresent(TicketMoveRead.self, forKey: .note)
    }

    /// The fields of a ticket read (`GET /api/v1/:issue_identifier`); nil for anything but a JSON object.
    public static func decode(_ data: Data) -> TicketDetailsRead? {
        try? JSONDecoder().decode(TicketDetailsRead.self, from: data)
    }
}

// MARK: - When

/// "today at 14:02", "yesterday at 09:10", "Fri 6 Nov at 18:40": a moment against `reference`'s day.
enum FactsMoment {
    static func say(_ date: Date, reference: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.timeZone = calendar.timeZone
        formatter.calendar = calendar
        formatter.dateFormat = "HH:mm"
        let time = formatter.string(from: date)
        if calendar.isDate(date, inSameDayAs: reference) { return "today at \(time)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: reference), calendar.isDate(date, inSameDayAs: yesterday) {
            return "yesterday at \(time)"
        }
        formatter.dateFormat = "EEE d MMM"
        return "\(formatter.string(from: date)) at \(time)"
    }
}

// MARK: - The Note for the next run panel

/// What the Note for the next run panel says: the note set, who set it and when, which run read it and when (or that
/// none has yet), and whether Save Note may write a new one.
public struct NotePanelModel: Equatable {
    public struct Current: Equatable {
        public var text: String
        /// "Set by Tony today at 14:02".
        public var setLine: String
        /// "Read by implementation run 3 at 14:02", or `notReadLine`.
        public var readLine: String
        public var read: Bool
        /// What the next run is told: `nextRunReadsLine` until a run read it, then `laterRunsLine`.
        public var confirmation: String
        public var accessibilityLabel: String
    }

    public var current: Current?
    /// Why no note can be written on the ticket now, from `moves.note`; nil when it can.
    public var refusal: String?

    public static let title = "Note for the next run"
    public static let emptyLine = "No note. The next run reads the ticket and its history only."
    public static let notReadLine = "Not read yet"
    public static let nextRunReadsLine = "The next run reads this note before it starts."
    public static let laterRunsLine = "Every later run still reads it in the ticket's history."
    public static let placeholder = "Write a note for the next run"
    public static let saveTitle = "Save Note"
    public static let savingTitle = "Saving…"
    /// Save's reason while the field is empty.
    public static let emptyFieldReason = "Write a note first."
    /// The line under the field: what a saved note does.
    public static let fieldHint = "The next run reads it first. A new note replaces this one."

    /// The panel from the read's `note` and `moves.note`; a reading run is named from `runs`, the ticket's run headers
    /// by run id. Dates read in `calendar`, against `reference`'s day.
    public static func build(
        note: TicketNoteRead?, move: TicketMoveRead?, runs: [String: TicketEventsPayload.Run], reference: Date,
        calendar: Calendar = .current
    ) -> NotePanelModel {
        let refusal = move.flatMap { $0.allowed ? nil : ($0.reason ?? "Symphony can't take a note on this ticket now.") }
        guard let note, !note.text.trimmingWhitespace().isEmpty else { return NotePanelModel(current: nil, refusal: refusal) }
        let when = note.at.map { FactsMoment.say($0, reference: reference, calendar: calendar) }
        let setLine = ["Set", note.by.map { "by \($0)" }, when].compactMap { $0 }.joined(separator: " ")
        let readLine: String
        if let readBy = note.readBy {
            let run = runName(runs[readBy.runID])
            let at = readBy.at.map { date -> String in
                let moment = FactsMoment.say(date, reference: reference, calendar: calendar)
                return moment.hasPrefix("today ") ? String(moment.dropFirst("today ".count)) : moment
            }
            readLine = ["Read by \(run)", at].compactMap { $0 }.joined(separator: " ")
        } else {
            readLine = notReadLine
        }
        let read = note.readBy != nil
        let confirmation = read ? laterRunsLine : nextRunReadsLine
        let current = Current(
            text: note.text, setLine: setLine, readLine: readLine, read: read, confirmation: confirmation,
            accessibilityLabel: ["Note for the next run", note.text, setLine, readLine].joined(separator: ", ")
        )
        return NotePanelModel(current: current, refusal: refusal)
    }

    /// Why Save Note is off for `text`: the ticket takes no note now, the field is empty, or the note is too long; nil
    /// when it may save.
    public func saveReason(_ text: String) -> String? {
        if let refusal { return refusal }
        let note = text.trimmingWhitespace()
        if note.isEmpty { return Self.emptyFieldReason }
        return TicketNoteComposer.tooLong(note)
    }

    /// "implementation run 3", "QA run 2", "code review run 1": a run as a sentence names it; "a run" when the ticket's
    /// history doesn't hold its header.
    static func runName(_ run: TicketEventsPayload.Run?) -> String {
        guard let run else { return "a run" }
        let title = TicketEventsPayload.runTitle(kind: run.runKind, number: run.runNumber)
        return title.split(separator: " ").map { word in
            word.count > 1 && word.allSatisfy(\.isUppercase) ? String(word) : word.lowercased()
        }
        .joined(separator: " ")
    }
}

// MARK: - The Decisions panel

/// What the Decisions panel says: the decisions recorded on the ticket, newest first, each folded to its label and
/// what was decided, unfolding into the question and the answer.
public struct DecisionsPanelModel: Equatable {
    public struct Row: Equatable, Identifiable {
        /// "D2".
        public var id: String
        /// The folded line: the decision's title, else its answer.
        public var headline: String
        /// When it was decided, as the record says it ("2026-11-10").
        public var date: String?
        /// The question it answered in its own words; nil for a ruling recorded without one.
        public var question: String?
        public var answer: String
        /// What it means for the ticket's scope.
        public var scope: String?
        public var accessibilityLabel: String
    }

    public var rows: [Row]

    public static let title = "Decisions"
    public static let emptyLine = "No decisions recorded on this ticket yet."
    /// The question's place on a ruling recorded without one.
    public static let noQuestionLine = "Recorded without a question."

    /// The panel from the ticket's decisions in the order recorded: the newest reads first.
    public static func build(_ decisions: [TicketDecision]) -> DecisionsPanelModel {
        DecisionsPanelModel(rows: decisions.reversed().map(row))
    }

    static func row(_ decision: TicketDecision) -> Row {
        let headline = decision.title?.trimmingWhitespace().nonEmpty ?? decision.answer
        let question = decision.question?.trimmingWhitespace().nonEmpty
        let spoken = ["Decision \(decision.id)", headline, decision.date.map { "decided \($0)" }].compactMap { $0 }
        return Row(
            id: decision.id, headline: headline, date: decision.date, question: question, answer: decision.answer,
            scope: decision.scope?.trimmingWhitespace().nonEmpty, accessibilityLabel: spoken.joined(separator: ", ")
        )
    }
}

// MARK: - The Details panel

/// What the Details panel says, as the Key-value list: the repo, priority, labels, workspace, each run's model and the
/// links out, then the brief with its walkthrough above the agent's description.
public struct DetailsPanelModel: Equatable {
    public struct RunModel: Equatable, Identifiable {
        public var id: String
        /// "Implementation run 2".
        public var run: String
        /// "claude-opus-5-5 · high effort".
        public var model: String
    }

    public struct Link: Equatable, Identifiable {
        public var id: String { title }
        /// "Ticket in Linear", "PR #741 on GitHub".
        public var title: String
        public var url: URL
    }

    public struct Brief: Equatable {
        public var text: String
        public var walkthrough: String?
        /// "Written today at 09:12".
        public var written: String?
    }

    public var repo: String?
    /// "Urgent", "High", "Medium", "Low", "No priority".
    public var priority: String?
    public var labels: [String]
    public var workspace: String?
    /// The machine the workspace is on, when Symphony names one.
    public var workspaceHost: String?
    public var models: [RunModel]
    /// The models' fold folded: "3 runs · claude-opus-5-5".
    public var modelsSummary: String?
    public var links: [Link]
    public var brief: Brief?
    /// The ticket's description the agent works from; nil when the app has none.
    public var agentDescription: String?

    public static let title = "Details"
    public static let briefTitle = "Brief"
    public static let walkthroughTitle = "Walkthrough"
    public static let agentDescriptionTitle = "Agent description"
    public static let noBriefLine = "No brief yet. The implementation run writes one when it starts."
    public static let noDescriptionLine = "The description the agent works from is on the ticket in Linear."
    public static let noLabelsLine = "None"
    public static let copyTitle = "Copy"
    public static let copiedTitle = "Copied"

    /// The panel from the ticket read, its run headers from the events feed (`runs`, by run id), the ticket's Linear
    /// URL and its pull request's, and its description when the app has one. Dates read in `calendar`, against
    /// `reference`'s day.
    public static func build(
        _ read: TicketDetailsRead?, runs: [String: TicketEventsPayload.Run], linearURL: URL?, pullRequest: TicketPullRequest?,
        description: String?, reference: Date, calendar: Calendar = .current
    ) -> DetailsPanelModel {
        let read = read ?? TicketDetailsRead()
        let models = runModels(runs)
        let brief = read.brief.flatMap { brief -> Brief? in
            guard let text = brief.text.trimmingWhitespace().nonEmpty else { return nil }
            return Brief(
                text: text, walkthrough: brief.walkthrough?.trimmingWhitespace().nonEmpty,
                written: brief.at.map { "Written " + FactsMoment.say($0, reference: reference, calendar: calendar) }
            )
        }
        var links: [Link] = []
        if let linearURL { links.append(Link(title: "Ticket in Linear", url: linearURL)) }
        if let pullRequest, let url = pullRequest.url { links.append(Link(title: "PR #\(pullRequest.number) on GitHub", url: url)) }
        return DetailsPanelModel(
            repo: read.repoKey?.nonEmpty, priority: read.ticket?.priority.flatMap(priorityWord),
            labels: read.ticket?.labels ?? [], workspace: read.workspace?.path.nonEmpty, workspaceHost: read.workspace?.host?.nonEmpty,
            models: models, modelsSummary: modelsSummary(models), links: links, brief: brief,
            agentDescription: description?.trimmingWhitespace().nonEmpty
        )
    }

    static func priorityWord(_ priority: Int) -> String? {
        TicketPriority.named(String(priority))?.title
    }

    /// Each run that names its model, oldest first.
    static func runModels(_ runs: [String: TicketEventsPayload.Run]) -> [RunModel] {
        runs.values
            .sorted { ($0.startedAt ?? "", $0.runID) < ($1.startedAt ?? "", $1.runID) }
            .compactMap { run in
                guard let model = run.model?.trimmingWhitespace().nonEmpty else { return nil }
                let effort = run.effort?.trimmingWhitespace().nonEmpty.map { "\($0) effort" }
                return RunModel(
                    id: run.runID, run: TicketEventsPayload.runTitle(kind: run.runKind, number: run.runNumber),
                    model: [model, effort].compactMap { $0 }.joined(separator: " · ")
                )
            }
    }

    /// "1 run · claude-opus-5-5", "3 runs · claude-opus-5-5, deepseek-v4": how many runs, and their models once each.
    static func modelsSummary(_ models: [RunModel]) -> String? {
        guard !models.isEmpty else { return nil }
        var names: [String] = []
        for model in models {
            let name = String(model.model.split(separator: " · ").first ?? "")
            if !names.contains(name) { names.append(name) }
        }
        return "\(models.count == 1 ? "1 run" : "\(models.count) runs") · \(names.joined(separator: ", "))"
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
