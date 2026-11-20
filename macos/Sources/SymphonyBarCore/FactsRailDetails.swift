import Foundation

// The ticket read's `ticket`, `brief`, `workspace` and `repo_key` (`docs/control-api.md` § `ticket`, § `brief`), the
// ticket's decisions (`GET /api/v1/tickets/:identifier/decisions`) and each run's model from its events feed, and what
// the facts rail's Decisions and Details panels say from them (`docs/design/director-ticket-page.md` §1 facts 17, 22
// to 25, 27, 30 and 33).

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

/// The ticket read's facts the Details panel says, each nil when the read holds none.
public struct TicketDetailsRead: Equatable, Decodable {
    public var repoKey: String?
    public var ticket: TicketRecordRead?
    public var brief: TicketBriefRead?
    public var workspace: TicketWorkspaceRead?

    public init(
        repoKey: String? = nil, ticket: TicketRecordRead? = nil, brief: TicketBriefRead? = nil, workspace: TicketWorkspaceRead? = nil
    ) {
        self.repoKey = repoKey
        self.ticket = ticket
        self.brief = brief
        self.workspace = workspace
    }

    private enum CodingKeys: String, CodingKey {
        case ticket, brief, workspace
        case repoKey = "repo_key"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        repoKey = try container.decodeIfPresent(String.self, forKey: .repoKey)
        ticket = try container.decodeIfPresent(TicketRecordRead.self, forKey: .ticket)
        brief = try container.decodeIfPresent(TicketBriefRead.self, forKey: .brief)
        workspace = try container.decodeIfPresent(TicketWorkspaceRead.self, forKey: .workspace)
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
        let time = SharedDateFormatter.string(date, format: "HH:mm", locale: SharedDateFormatter.british, calendar: calendar)
        if calendar.isDate(date, inSameDayAs: reference) { return "today at \(time)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: reference), calendar.isDate(date, inSameDayAs: yesterday) {
            return "yesterday at \(time)"
        }
        let day = SharedDateFormatter.string(date, format: "EEE d MMM", locale: SharedDateFormatter.british, calendar: calendar)
        return "\(day) at \(time)"
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
        /// "Claude Opus 5.5 · high effort": the model's name as the timeline reads it.
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
    /// The models' fold folded: "3 runs · Claude Opus 5.5".
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
                let modelID = run.model?.trimmingWhitespace().nonEmpty
                guard let model = run.modelName?.trimmingWhitespace().nonEmpty ?? modelID.map(ModelName.display) else {
                    return nil
                }
                let effort = run.effort?.trimmingWhitespace().nonEmpty.map { "\($0) effort" }
                return RunModel(
                    id: run.runID, run: TicketEventsPayload.runTitle(kind: run.runKind, number: run.runNumber),
                    model: [model, effort].compactMap { $0 }.joined(separator: " · ")
                )
            }
    }

    /// "1 run · Claude Opus 5.5", "3 runs · Claude Opus 5.5, Deepseek V4": how many runs, and their models once each.
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
