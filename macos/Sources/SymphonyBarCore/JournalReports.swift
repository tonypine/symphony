import Foundation

// Reports in the Journal (TP-1462; analysis §2.6, push-back 2 and §6.4): each status report Symphony published
// (`GET /api/v1/reports`, `docs/control-api.md`), pinned among the Journal's events at the end of its period, as a card:
// the period, the report's sentences as one paragraph with each cited sentence a link, the model that wrote it, and the
// Question it raised while it is open. A report cites events by id; the events read resolves them to their tickets
// (`JournalCitations`), from the Journal's own pages or, for a period the pages don't hold, from the read of the period's
// notable events the report run itself read. A citation opens its ticket's page at the event.

/// A published report, as the reports read serves it.
public struct JournalReport: Equatable, Identifiable {
    /// The events one sentence rests on, by the sentence's index.
    public struct Citation: Equatable, Decodable {
        public var sentence: Int
        public var events: [String]

        public init(sentence: Int, events: [String]) {
            self.sentence = sentence
            self.events = events
        }
    }

    public struct Period: Equatable, Decodable {
        public var from: String?
        public var to: String?

        public init(from: String? = nil, to: String? = nil) {
            self.from = from
            self.to = to
        }
    }

    public var id: String
    /// When it was published.
    public var at: String?
    public var runID: String?
    /// The model that wrote it.
    public var model: String?
    public var period: Period
    /// The tickets it rests on, by identifier.
    public var tickets: [String]
    /// The events it cites, by id.
    public var events: [String]
    /// Its sentences in reading order: the text is them, one after the other.
    public var sentences: [String]
    public var text: String?
    public var citations: [Citation]
    /// The Question it raised; nil for none.
    public var questionID: String?

    public init(
        id: String, at: String? = nil, runID: String? = nil, model: String? = nil, period: Period = Period(), tickets: [String] = [],
        events: [String] = [], sentences: [String] = [], text: String? = nil, citations: [Citation] = [], questionID: String? = nil
    ) {
        self.id = id
        self.at = at
        self.runID = runID
        self.model = model
        self.period = period
        self.tickets = tickets
        self.events = events
        self.sentences = sentences
        self.text = text
        self.citations = citations
        self.questionID = questionID
    }

    /// The end of its period: where the Journal pins it; its publishing time for a report whose period doesn't read.
    public var pinnedAt: Date? {
        period.to.flatMap(TicketPage.date) ?? at.flatMap(TicketPage.date)
    }

    /// The ids sentence `index` cites, in the order the report gives them.
    public func cited(_ index: Int) -> [String] {
        citations.filter { $0.sentence == index }.flatMap(\.events)
    }

    /// The read of the period's notable events, the ones its run read and cited: nil for a period that doesn't read.
    public var periodEventsPath: String? {
        guard let from = period.from, let to = period.to else { return nil }
        let parameters = [
            ("limit", String(JournalQuery.pageSize)), ("notable", "true"), ("since", from), ("until", to),
        ]
        return JournalQuery.path + "?" + parameters.map { "\($0.0)=\(JournalQuery.encode($0.1))" }.joined(separator: "&")
    }
}

/// A read of the published reports, newest first.
public struct JournalReportsPayload: Equatable {
    public var reports: [JournalReport]

    public init(reports: [JournalReport]) {
        self.reports = reports
    }

    public static let path = "api/v1/reports"

    /// The reports published after `since` (exclusive), or every one.
    public static func path(since: String? = nil) -> String {
        guard let since else { return path }
        return path + "?since=" + JournalQuery.encode(since)
    }

    /// The reports of a read, nil when it isn't one; a report that doesn't read (no id) is skipped, not the read.
    public static func decode(_ data: Data) -> JournalReportsPayload? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let page = try? decoder.decode(Page.self, from: data) else { return nil }
        return JournalReportsPayload(reports: page.reports.compactMap(\.report))
    }

    private struct Page: Decodable {
        let reports: [Entry]
    }

    private struct Entry: Decodable {
        let report: JournalReport?

        private struct Fields: Decodable {
            let id: String
            let at: String?
            let runId: String?
            let model: String?
            let period: JournalReport.Period?
            let tickets: [String]?
            let events: [String]?
            let sentences: [String]?
            let text: String?
            let citations: [JournalReport.Citation]?
            let questionId: String?
        }

        init(from decoder: Decoder) throws {
            guard let fields = try? Fields(from: decoder) else {
                report = nil
                return
            }
            report = JournalReport(
                id: fields.id, at: fields.at, runID: fields.runId, model: fields.model, period: fields.period ?? .init(),
                tickets: fields.tickets ?? [], events: fields.events ?? [], sentences: fields.sentences ?? [], text: fields.text,
                citations: fields.citations ?? [], questionID: fields.questionId
            )
        }
    }
}

/// The events reports cite, by id, with the ticket each is on: from the Journal's pages and the reads of the periods.
public struct JournalCitations: Equatable {
    public private(set) var events: [String: JournalPayload.Event] = [:]

    public init(_ events: [JournalPayload.Event] = []) {
        take(events)
    }

    /// Keeps `events` for the citations that name them.
    public mutating func take(_ events: [JournalPayload.Event]) {
        for event in events { self.events[event.id] = event }
    }

    /// Whether every event `report` cites is known: its period needs no read of its own.
    public func resolves(_ report: JournalReport) -> Bool {
        report.events.allSatisfy { events[$0] != nil }
    }

    /// Where the citation of event `id` opens: its ticket's page at that event; nil for an event not known yet, or one on
    /// Symphony's own stream, which no ticket page holds.
    public func focus(_ id: String) -> TimelineFocus? {
        guard let event = events[id], let identifier = event.ticket.identifier else { return nil }
        return TimelineFocus(identifier: identifier, eventID: id, runID: event.event.runID ?? event.by?.runId)
    }

    /// Whether event `id` is known: a citation of it can show its row in the Journal, on a ticket or on Symphony's own
    /// stream.
    public func knows(_ id: String) -> Bool {
        events[id] != nil
    }

    /// The tickets the known events are on, as a text's chips find them: by identifier, with their title and repository.
    public var references: [String: Reference] {
        var references: [String: Reference] = [:]
        for event in events.values.sorted(by: { $0.id < $1.id }) {
            guard let identifier = event.ticket.identifier, references[identifier] == nil else { continue }
            references[identifier] = .ticket(Reference.Ticket(identifier: identifier, title: event.ticket.title, repoKey: event.ticket.repoKey))
        }
        return references
    }
}

/// A report as its card in the Journal draws it.
public struct JournalReportCard: Equatable, Identifiable {
    /// One sentence of the paragraph: where it sits in `text`, the events it cites and where its link opens.
    public struct Sentence: Equatable, Identifiable {
        public var index: Int
        public var text: String
        /// Its place in the card's `text`, in UTF-16 units.
        public var range: NSRange
        /// The ids of the events it cites.
        public var events: [String]
        /// Each cited event's ticket page, for the events that resolve, in the order the report cites them.
        public var focuses: [TimelineFocus]
        /// The cited events the Journal knows, on a ticket or on Symphony's own stream, in the order the report cites
        /// them: their rows are where a citation with no ticket page shows its facts.
        public var rows: [String]

        public var id: Int { index }

        public init(index: Int, text: String, range: NSRange, events: [String], focuses: [TimelineFocus], rows: [String] = []) {
            self.index = index
            self.text = text
            self.range = range
            self.events = events
            self.focuses = focuses
            self.rows = rows
        }

        /// The link opens the first event it cites that resolves; nil when none does.
        public var focus: TimelineFocus? { focuses.first }

        /// The Journal row a link with no ticket page shows (an event on Symphony's own stream): nil when the sentence
        /// opens a ticket page, or cites no event the Journal knows.
        public var row: String? { focus == nil ? rows.first : nil }

        /// Whether the sentence is a link: it opens a ticket page at its event, or shows its event's row in the Journal.
        public var linked: Bool { focus != nil || row != nil }

        /// The link's help and VoiceOver action: "Open TP-1457 at the event this sentence rests on", or "Show the event
        /// this sentence rests on in the Journal" for one on Symphony's own stream.
        public var linkLabel: String? {
            if let focus { return "Open \(focus.identifier) at the event this sentence rests on" }
            return row == nil ? nil : Self.showLabel
        }

        public static let showLabel = "Show the event this sentence rests on in the Journal"
    }

    public var id: String
    /// The end of its period: where it pins.
    public var at: Date
    /// "21:00 – 03:00", or with the days when the period spans more than one: "Wed 11 Nov 18:00 – Thu 12 Nov 03:00".
    public var period: String
    public var model: String?
    /// The sentences, one after the other with a space between.
    public var text: String
    public var sentences: [Sentence]
    public var questionID: String?
    /// The tickets the report rests on, in its order, each a chip under the paragraph that opens it at its first cited
    /// event.
    public var tickets: [TimelineFocus]
    /// The chips of the paragraph's ticket mentions.
    public var references: [String: Reference]

    public static let kicker = "Report"

    /// "Written by claude-haiku-5-5".
    public var modelLine: String? { model.map { "Written by \($0)" } }

    /// "Report, 21:00 – 03:00, 3 sentences, written by claude-haiku-5-5".
    public var accessibilityLabel: String {
        [Self.kicker, period, sentences.count == 1 ? "1 sentence" : "\(sentences.count) sentences", model.map { "written by \($0)" }]
            .compactMap { $0 }
            .joined(separator: ", ")
    }

    /// The events the card cites on `ticket`: the rows a hover over its chip lights.
    public func events(of ticket: String) -> [String] {
        sentences.flatMap { sentence in sentence.focuses.filter { $0.identifier == ticket }.map(\.eventID) }
    }

    /// The card of `report`, its citations resolved through `citations`; nil for a report with no sentence or no time.
    public static func build(_ report: JournalReport, citations: JournalCitations, calendar: Calendar) -> JournalReportCard? {
        guard let at = report.pinnedAt else { return nil }
        let texts = report.sentences.isEmpty ? [report.text].compactMap { $0 } : report.sentences
        let trimmed = texts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard trimmed.contains(where: { !$0.isEmpty }) else { return nil }
        var text = ""
        var sentences: [Sentence] = []
        for (index, sentence) in trimmed.enumerated() where !sentence.isEmpty {
            if !text.isEmpty { text += " " }
            let range = NSRange(location: (text as NSString).length, length: (sentence as NSString).length)
            text += sentence
            let events = report.cited(index)
            sentences.append(Sentence(
                index: index, text: sentence, range: range, events: events, focuses: events.compactMap(citations.focus),
                rows: events.filter(citations.knows)
            ))
        }
        var tickets: [TimelineFocus] = []
        for focus in sentences.flatMap(\.focuses) where !tickets.contains(where: { $0.identifier == focus.identifier }) {
            tickets.append(focus)
        }
        return JournalReportCard(
            id: report.id, at: at, period: period(report, calendar: calendar), model: report.model?.trimmingWhitespace().nilIfEmpty,
            text: text, sentences: sentences, questionID: report.questionID, tickets: tickets, references: citations.references
        )
    }

    /// The period in the card's header.
    static func period(_ report: JournalReport, calendar: Calendar) -> String {
        let clock = TimelineModel.clock(calendar)
        guard let from = report.period.from.flatMap(TicketPage.date), let to = report.period.to.flatMap(TicketPage.date) else {
            return report.pinnedAt.map(clock) ?? ""
        }
        guard calendar.isDate(from, inSameDayAs: to) || (calendar.dateComponents([.hour], from: from, to: to).hour ?? 0) < 24 else {
            return "\(TimelineModel.dayDate(from, calendar)) \(clock(from)) – \(TimelineModel.dayDate(to, calendar)) \(clock(to))"
        }
        return "\(clock(from)) – \(clock(to))"
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
