import Foundation

// The ticket read's `ticket`, `brief`, `workspace` and `repo_key` (`docs/control-api.md` § `ticket`, § `brief`) and
// the ticket's decisions (`GET /api/v1/tickets/:identifier/decisions`), and what the facts rail's Decisions panel says
// from them. The brief on top of the page is `BriefPanelModel`'s.

/// The ticket as its record holds it: its title, phase, Linear priority, labels and description.
public struct TicketRecordRead: Equatable, Decodable {
    public var title: String?
    public var phase: String?
    /// Linear's: 0 none, 1 urgent, 2 high, 3 medium, 4 low; nil when unknown.
    public var priority: Int?
    public var labels: [String]
    /// The description as a run receives it, without Symphony's summary block.
    public var description: String?

    public init(title: String? = nil, phase: String? = nil, priority: Int? = nil, labels: [String] = [], description: String? = nil) {
        self.title = title
        self.phase = phase
        self.priority = priority
        self.labels = labels
        self.description = description
    }

    private enum CodingKeys: String, CodingKey { case title, phase, priority, labels, description }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        phase = try container.decodeIfPresent(String.self, forKey: .phase)
        priority = try container.decodeIfPresent(Int.self, forKey: .priority)
        labels = try container.decodeIfPresent([String].self, forKey: .labels) ?? []
        description = try container.decodeIfPresent(String.self, forKey: .description)
    }
}

/// What the ticket does and why, in a person's words, with its walkthrough: written by an implementation, rework or
/// review-feedback run, named by `by`.
public struct TicketBriefRead: Equatable, Decodable {
    public var text: String
    public var walkthrough: String?
    public var at: Date?
    /// The run that wrote it (`by.run_id`), and its kind (`by.run_kind`).
    public var runID: String?
    public var runKind: String?

    public init(text: String, walkthrough: String? = nil, at: Date? = nil, runID: String? = nil, runKind: String? = nil) {
        self.text = text
        self.walkthrough = walkthrough
        self.at = at
        self.runID = runID
        self.runKind = runKind
    }

    private enum CodingKeys: String, CodingKey { case text, walkthrough, at, by }

    private struct Author: Decodable {
        var runID: String?
        var runKind: String?

        private enum CodingKeys: String, CodingKey {
            case runID = "run_id"
            case runKind = "run_kind"
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        walkthrough = try container.decodeIfPresent(String.self, forKey: .walkthrough)
        at = try container.decodeIfPresent(String.self, forKey: .at).flatMap(SymphonyState.parseDate)
        let author = try? container.decodeIfPresent(Author.self, forKey: .by)
        runID = author?.runID
        runKind = author?.runKind
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

/// The ticket read's facts the page says beside its timeline: the brief, the record's ticket, the workspace; each nil
/// when the read holds none.
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

/// What the Decisions panel says: one row per decision the person recorded on the ticket, newest first, each the
/// decision and, under it, who answered and when (the catalog's `decisionsPanel`, TP-1504). A ticket with none has no
/// panel.
public struct DecisionsPanelModel: Equatable {
    public struct Row: Equatable, Identifiable {
        /// "D2".
        public var id: String
        /// The decision: its title, else its answer.
        public var title: String
        /// "You · today", "You · yesterday", "You · Fri 6 Nov".
        public var byline: String
        public var accessibilityLabel: String
    }

    public var rows: [Row]

    /// No decision: the page draws no Decisions label and no panel.
    public var isEmpty: Bool { rows.isEmpty }

    public static let title = "Decisions"
    /// Who answers a ticket's questions and records its rulings.
    public static let answeredBy = "You"

    /// The panel from the ticket's decisions in the order recorded: the newest reads first. Days read in `calendar`,
    /// against `reference`'s.
    public static func build(_ decisions: [TicketDecision], reference: Date = Date(), calendar: Calendar = .current) -> DecisionsPanelModel {
        DecisionsPanelModel(rows: decisions.reversed().map { row($0, reference: reference, calendar: calendar) })
    }

    static func row(_ decision: TicketDecision, reference: Date, calendar: Calendar) -> Row {
        let title = decision.title?.trimmingWhitespace().nonEmpty ?? decision.answer.trimmingWhitespace()
        let when: String? = decision.date.map { Self.day($0, reference: reference, calendar: calendar) }
        let byline = [answeredBy, when].compactMap { $0 }.joined(separator: " · ")
        let spoken = ["Decision \(decision.id)", title, "answered by you" + (when.map { ", \($0)" } ?? "")]
        return Row(id: decision.id, title: title, byline: byline, accessibilityLabel: spoken.joined(separator: ", "))
    }

    /// "today", "yesterday", "Fri 6 Nov": a record's "2026-11-10" against `reference`'s day; as written when it is no
    /// date.
    static func day(_ date: String, reference: Date, calendar: Calendar) -> String {
        let parts = date.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              let day = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
        else { return date }
        if calendar.isDate(day, inSameDayAs: reference) { return "today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: reference), calendar.isDate(day, inSameDayAs: yesterday) {
            return "yesterday"
        }
        let sameYear = calendar.component(.year, from: day) == calendar.component(.year, from: reference)
        return SharedDateFormatter.string(day, format: sameYear ? "EEE d MMM" : "d MMM yyyy", locale: SharedDateFormatter.british, calendar: calendar)
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
