import Foundation

// The ticket page's Timeline section (`docs/design/director-ticket-page.md` §1 facts 12 and 32, §4, and the catalog's
// Timeline and Timeline entry): a ticket's history newest first, one entry per thing that happened with a glyph per
// class and who did it, runs folded into their Run groups, and a separator on each day. Writes that changed nothing
// for the ticket fold into the entry they belong to: a pause reads once with how long it lasted, a move once with who
// made it, a write recorded twice once.

/// One thing that happened to a ticket, as its timeline row shows it.
public struct TimelineEntry: Equatable, Identifiable {
    /// The entry's class: its glyph, and its tone, which says the outcome only where there is one.
    public enum Kind: String, CaseIterable, Equatable {
        case phase, pause, pauseCleared, questionAsked, questionAnswered, questionClosed, runStarted, runPassed, runFailed
        case runStopped, person, rule, finding, findingResolved, note, ticket, situation, other

        public var symbol: String {
            switch self {
            case .phase: "arrow.right.circle"
            case .pause: "pause.circle"
            case .pauseCleared: "play.circle"
            case .questionAsked: "bubble.left"
            case .questionAnswered: "checkmark.bubble"
            case .questionClosed: "bubble.left"
            case .runStarted: "play.circle"
            case .runPassed: "checkmark.circle.fill"
            case .runFailed: "xmark.circle.fill"
            case .runStopped: "stop.circle"
            case .person: "hand.raised"
            case .rule: "gearshape"
            case .finding: "ladybug"
            case .findingResolved: "ladybug"
            case .note: "note.text"
            case .ticket: "doc.badge.plus"
            case .situation: "arrow.clockwise"
            case .other: "circle"
            }
        }

        public var tone: Tone {
            switch self {
            case .phase, .person: .accent
            case .pause, .questionClosed, .runStopped, .rule, .findingResolved, .note, .ticket, .other: .status(.idle)
            case .pauseCleared, .runStarted: .status(.working)
            case .questionAsked: .status(.you)
            case .questionAnswered, .runPassed: .status(.done)
            case .runFailed, .finding, .situation: .status(.problem)
            }
        }

        /// VoiceOver's word for the class: "phase move", "pause".
        public var word: String {
            switch self {
            case .phase: "phase move"
            case .pause: "pause"
            case .pauseCleared: "pause cleared"
            case .questionAsked: "question asked"
            case .questionAnswered: "question answered"
            case .questionClosed: "question"
            case .runStarted: "run started"
            case .runPassed: "passed"
            case .runFailed: "failed"
            case .runStopped: "stopped"
            case .person: "your action"
            case .rule: "rule action"
            case .finding: "finding"
            case .findingResolved: "finding resolved"
            case .note: "note"
            case .ticket: "ticket"
            case .situation: "situation"
            case .other: "event"
            }
        }
    }

    /// The glyph's colour: the accent for a move and a person's action, else a status's.
    public enum Tone: Equatable {
        case accent
        case status(DesignTokens.Status)
    }

    /// The first event folded into it.
    public var id: String
    public var kind: Kind
    public var at: Date
    /// What happened: "Entered In Progress from Todo", "Paused: waiting for TP-1443 to finish".
    public var title: String
    public var detail: String?
    /// Who did it: "Symphony", a rule ("Rule: CI wait"), a person, a run ("Implementation run 2").
    public var actor: String
    /// A pause's end; nil while it lasts.
    public var endedAt: Date?
    /// How long a pause lasted, or has so far.
    public var durationSeconds: Int?
    /// Every event folded into it, in the order Symphony wrote them.
    public var eventIDs: [String]
    /// One of its events is newer than the person's last look: it carries the new dot (TP-1451).
    public var isNew: Bool

    public init(
        id: String, kind: Kind, at: Date, title: String, detail: String? = nil, actor: String, endedAt: Date? = nil,
        durationSeconds: Int? = nil, eventIDs: [String]? = nil, isNew: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.at = at
        self.title = title
        self.detail = detail
        self.actor = actor
        self.endedAt = endedAt
        self.durationSeconds = durationSeconds
        self.eventIDs = eventIDs ?? [id]
        self.isNew = isNew
    }

    /// A pause that still holds the ticket.
    public var isOngoing: Bool { kind == .pause && endedAt == nil }

    /// "35 min", "4 min so far": how long a pause lasted.
    public var duration: String? {
        durationSeconds.map { Overview.duration($0) + (isOngoing ? " so far" : "") }
    }

    /// The bold words that say what happened: up to and with the first colon, else the whole title.
    public var lead: String {
        guard let colon = title.range(of: ": ") else { return title }
        return String(title[..<colon.upperBound]).trimmingCharacters(in: .whitespaces)
    }

    /// The rest of the title after `lead`, nil when there is none.
    public var rest: String? {
        guard let colon = title.range(of: ": ") else { return nil }
        let rest = title[colon.upperBound...].trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? nil : rest
    }

    /// The entry for VoiceOver, as one sentence: "09:30, pause, Paused: deploy freeze, lasted 35 minutes, by Tony",
    /// and ", new since you last looked" when it carries the dot.
    public func accessibilityLabel(time: String) -> String {
        let lasted = durationSeconds.map { (isOngoing ? "for " : "lasted ") + Overview.spokenDuration($0) + (isOngoing ? " so far" : "") }
        let new = isNew ? Self.newWords : nil
        return ([time, kind.word, title, detail, lasted, "by " + actor, new].compactMap { $0 }).joined(separator: ", ")
    }

    /// What the new dot says to VoiceOver.
    public static let newWords = "new since you last looked"
    /// The dot's help, under the pointer.
    public static let newHelp = "New since you last looked"
}

/// One line of the timeline: an entry, or a run folded into its group.
public enum TimelineItem: Equatable, Identifiable {
    case entry(TimelineEntry)
    case run(RunGroupModel, at: Date)

    public var id: String {
        switch self {
        case let .entry(entry): "entry-\(entry.id)"
        case let .run(run, _): "run-\(run.id)"
        }
    }

    public var at: Date {
        switch self {
        case let .entry(entry): entry.at
        case let .run(_, at): at
        }
    }

    /// When it ended: a pause's end, a run's start plus its duration; else when it happened.
    var end: Date {
        switch self {
        case let .entry(entry): entry.endedAt ?? entry.at
        case let .run(run, at): at.addingTimeInterval(TimeInterval(run.durationSeconds ?? 0))
        }
    }

    public var run: RunGroupModel? {
        if case let .run(run, _) = self { return run }
        return nil
    }

    /// Newer than the person's last look: an entry or a run with a new event.
    public var isNew: Bool {
        switch self {
        case let .entry(entry): entry.isNew
        case let .run(run, _): run.isNew
        }
    }
}

/// The line "Since you last looked, at 16:50" between what is new and what the person saw (TP-1451).
public struct TimelineMarker: Equatable {
    /// When the person last looked: the line's time.
    public var lookedAt: Date
    /// The item the line sits above: the newest one the person saw.
    public var before: String

    public init(lookedAt: Date, before: String) {
        self.lookedAt = lookedAt
        self.before = before
    }
}

/// An event a ticket page opens at (the Journal's row, TP-1459): the page selects the timeline's item that holds it and
/// scrolls it into view.
public struct TimelineFocus: Equatable, Hashable {
    /// The ticket whose page opens.
    public var identifier: String
    public var eventID: String
    /// The run the event was recorded for, whose group holds it when no entry does.
    public var runID: String?

    public init(identifier: String, eventID: String, runID: String? = nil) {
        self.identifier = identifier
        self.eventID = eventID
        self.runID = runID
    }
}

/// The entries of one day, newest first, under its separator.
public struct TimelineDay: Equatable, Identifiable {
    /// "2026-10-08".
    public var id: String
    /// "Today", "Yesterday", else nil: the date says it.
    public var relative: String?
    /// "Thu 8 Oct".
    public var date: String
    /// "over 2 h 38 min": from the day's first thing to its last; nil when it holds one moment.
    public var span: String?
    public var items: [TimelineItem]

    public init(id: String, relative: String?, date: String, span: String?, items: [TimelineItem]) {
        self.id = id
        self.relative = relative
        self.date = date
        self.span = span
        self.items = items
    }

    /// The separator's words: "Today, Thu 8 Oct", "Wed 7 Oct".
    public var title: String { [relative, date].compactMap { $0 }.joined(separator: ", ") }

    /// The separator for VoiceOver: "Today, Thu 8 Oct, over 2 hours 38 minutes".
    public var accessibilityLabel: String { [title, spokenSpan].compactMap { $0 }.joined(separator: ", ") }

    var spokenSpan: String?
}

/// A ticket's timeline: its days, newest first, each with its entries and runs newest first; the run now at the top.
public struct TimelineModel: Equatable {
    public var days: [TimelineDay]
    /// Where the person last looked; nil on a first visit, and when nothing is new or nothing was seen.
    public var marker: TimelineMarker?

    public init(days: [TimelineDay], marker: TimelineMarker? = nil) {
        self.days = days
        self.marker = marker
    }

    /// Every item, top to bottom: the order the arrow keys move the selection in.
    public var items: [TimelineItem] { days.flatMap(\.items) }

    public var isEmpty: Bool { days.isEmpty }

    /// The run working on the ticket, on top of the timeline; nil when none is.
    public var runNow: RunGroupModel? {
        items.first?.run.flatMap { $0.isLive ? $0 : nil }
    }

    /// The run `id`, as the timeline has it now.
    public func run(_ id: String) -> RunGroupModel? {
        items.lazy.compactMap(\.run).first { $0.id == id }
    }

    public static let empty = "Nothing has happened to this ticket yet."

    /// The item that holds `focus`'s event: the entry it folded into, else its run's group; nil while the history read
    /// holds neither (the page selects and scrolls to it once it does).
    public func item(holding focus: TimelineFocus) -> String? {
        let holder = items.first { item in
            if case let .entry(entry) = item { return entry.eventIDs.contains(focus.eventID) }
            return false
        }
        if let holder { return holder.id }
        guard let runID = focus.runID else { return nil }
        return items.first { $0.run?.id == runID }?.id
    }

    /// The selection `steps` items down (up when negative) from `selection`; the first item when nothing is selected
    /// and the keys go down, the last when they go up. It stops at either end.
    public func moving(_ selection: String?, by steps: Int) -> String? {
        let ids = items.map(\.id)
        guard !ids.isEmpty, steps != 0 else { return selection }
        guard let selection, let index = ids.firstIndex(of: selection) else { return steps > 0 ? ids.first : ids.last }
        return ids[min(max(index + steps, 0), ids.count - 1)]
    }

    // MARK: - Building

    /// The history as the timeline: `runNow` and `liveTokens` go to the running run, durations so far count to
    /// `reference`, and the days and times are `calendar`'s. `lookedAt`, when the person last looked, keeps the feed's
    /// `new` as the dots and draws the marker; nil, a first visit, draws neither (the feed calls everything new then).
    public static func build(
        _ history: TicketEventsPayload, runNow: RunNow? = nil, liveTokens: Int? = nil, reference: Date, calendar: Calendar,
        lookedAt: Date? = nil
    ) -> TimelineModel {
        let newRuns: Set<String> = lookedAt == nil ? [] : Set(history.events.filter(\.isNew).compactMap(\.runID))
        let runs = RunGroupModel.groups(history, runNow: runNow, liveTokens: liveTokens, reference: reference).map { run in
            var run = run
            run.isNew = newRuns.contains(run.id)
            return run
        }
        let runItems: [TimelineItem] = runs.compactMap { run in
            let header = history.runs[run.id]
            let first = history.events.lazy.filter { $0.runID == run.id }.compactMap(\.date).first
            guard let at = header?.startedDate ?? first else { return nil }
            return .run(run, at: at)
        }
        let entries = self.entries(history, reference: reference).map { entry in
            var entry = entry
            if lookedAt == nil { entry.isNew = false }
            return TimelineItem.entry(entry)
        }
        // Newest first; the run now on top, whenever it started.
        let ordered = (entries + runItems).enumerated().sorted { lhs, rhs in
            let left = lhs.element, right = rhs.element
            if (left.run?.isLive ?? false) != (right.run?.isLive ?? false) { return left.run?.isLive ?? false }
            return left.at == right.at ? lhs.offset > rhs.offset : left.at > right.at
        }.map(\.element)
        return TimelineModel(
            days: days(ordered, reference: reference, calendar: calendar), marker: lookedAt.flatMap { marker(ordered, lookedAt: $0) }
        )
    }

    /// The marker above the newest item the person saw, newest first in `items`, when something new is above it. The
    /// run now, on top whenever it started, doesn't say where the line goes.
    static func marker(_ items: [TimelineItem], lookedAt: Date) -> TimelineMarker? {
        var newAbove = false
        for item in items {
            if item.isNew {
                newAbove = true
            } else if item.run?.isLive != true {
                return newAbove ? TimelineMarker(lookedAt: lookedAt, before: item.id) : nil
            }
        }
        return nil
    }

    /// The items cut into days by the day each happened, newest first. The run now sits in the newest day.
    static func days(_ items: [TimelineItem], reference: Date, calendar: Calendar) -> [TimelineDay] {
        var days: [TimelineDay] = []
        for item in items {
            let day = item.run?.isLive == true ? days.first.map(\.id) ?? dayID(reference, calendar) : dayID(item.at, calendar)
            if let index = days.firstIndex(where: { $0.id == day }) {
                days[index].items.append(item)
            } else {
                let date = item.run?.isLive == true && days.isEmpty ? reference : item.at
                days.append(TimelineDay(
                    id: day, relative: relative(date, reference: reference, calendar: calendar),
                    date: dayDate(date, calendar), span: nil, items: [item]
                ))
            }
        }
        return days.map { day in
            var day = day
            let start = day.items.map(\.at).min(), end = day.items.map(\.end).max()
            if let start, let end {
                let seconds = Int(end.timeIntervalSince(start))
                if seconds >= 60 {
                    day.span = "over " + Overview.duration(seconds)
                    day.spokenSpan = "over " + Overview.spokenDuration(seconds)
                }
            }
            return day
        }
    }

    static func dayID(_ date: Date, _ calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func relative(_ date: Date, reference: Date, calendar: Calendar) -> String? {
        if calendar.isDate(date, inSameDayAs: reference) { return "Today" }
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: reference) else { return nil }
        return calendar.isDate(date, inSameDayAs: yesterday) ? "Yesterday" : nil
    }

    /// "Thu 8 Oct".
    static func dayDate(_ date: Date, _ calendar: Calendar) -> String {
        SharedDateFormatter.string(date, format: "EEE d MMM", calendar: calendar)
    }

    /// "09:02", in `calendar`'s time zone.
    public static func clock(_ calendar: Calendar) -> (Date) -> String {
        { SharedDateFormatter.string($0, format: "HH:mm", calendar: calendar) }
    }

    // MARK: - Entries

    /// The events a run's group stands for: they fold into it.
    static let runTypes: Set<String> = [
        "run.started", "run.ended", "step.started", "step.completed", "step.skipped", "attempt.pushed", "verdict.recorded",
        "evidence", "checklist.answered",
    ]

    /// Bookkeeping that changes nothing a person reads.
    static let silentTypes: Set<String> = ["note.read"]

    /// The situations worth an entry of their own; every other restates an entry beside it (a pause, a run, a question).
    static let situationsShown: Set<String> = ["retrying"]

    /// A pause set again this soon after it cleared, for the same reason, is the same pause.
    static let pauseRejoin: TimeInterval = 120
    /// A rule's action or a phase entered this close to the entry it caused folds into it.
    static let causeWindow: TimeInterval = 10

    /// The entries of the events no run's group stands for, oldest first, with the writes that changed nothing
    /// folded into the entry they belong to.
    static func entries(_ history: TicketEventsPayload, reference: Date) -> [TimelineEntry] {
        var drafts: [Draft] = []
        var openPause: [String: Int] = [:]
        var rules: [(event: TicketEventsPayload.Event, at: Date, order: Int)] = []

        for (order, event) in history.events.enumerated() {
            guard let at = event.date, !silentTypes.contains(event.type) else { continue }
            if let runID = event.runID, history.runs[runID] != nil, runTypes.contains(event.type) { continue }
            if event.type == "situation.changed", !situationsShown.contains(event.payload.to ?? "") { continue }
            if event.type == "rule.action", ruleCauses.contains(event.payload.action ?? "") {
                rules.append((event, at, order))
                continue
            }
            let draft = Draft(event, at: at, order: order, kind: kind(event), actor: actor(event, history: history))

            // A pause: its set opens one entry, each reason added or cleared folds into it, and its clear ends it.
            if let slot = pauseSlot(event.type) {
                if ["pause.set", "hold.set", "pause.reason_added"].contains(event.type) {
                    if let index = openPause[slot] {
                        drafts[index].fold(event, at: at, also: draft.entry.title)
                    } else if let index = drafts.lastIndex(where: { $0.slot == slot }), let ended = drafts[index].entry.endedAt,
                              at.timeIntervalSince(ended) <= pauseRejoin, drafts[index].entry.title == draft.entry.title {
                        // Set again at once for the same reason: the same pause goes on.
                        drafts[index].entry.endedAt = nil
                        drafts[index].fold(event, at: at)
                        openPause[slot] = index
                    } else {
                        var pause = draft
                        pause.entry.kind = .pause
                        pause.slot = slot
                        drafts.append(pause)
                        openPause[slot] = drafts.count - 1
                    }
                } else if let index = openPause[slot] {
                    if event.type != "pause.reason_cleared" {
                        drafts[index].entry.endedAt = at
                        openPause[slot] = nil
                    }
                    drafts[index].fold(event, at: at)
                } else {
                    var cleared = draft
                    cleared.entry.kind = .pauseCleared
                    drafts.append(cleared)
                }
                continue
            }
            drafts.append(draft)
        }

        drafts = foldMoves(drafts)

        // A rule that paused, lifted or moved the ticket is who did the entry it caused.
        for (event, at, order) in rules {
            let rule = ruleName(event)
            let near = { (moment: Date) in abs(moment.timeIntervalSince(at)) <= causeWindow }
            let caused: Int? = if event.payload.action == "moved" {
                drafts.indices.last(where: { drafts[$0].entry.kind == .phase && near(drafts[$0].entry.at) })
            } else {
                drafts.indices.last(where: { drafts[$0].slot != nil && drafts[$0].moments.contains(where: near) })
            }
            if let caused {
                if drafts[caused].entry.actor == symphony { drafts[caused].entry.actor = rule }
                drafts[caused].fold(event, at: at)
            } else {
                drafts.append(Draft(event, at: at, order: order, kind: .rule, actor: rule))
            }
        }
        drafts.sort { $0.entry.at == $1.entry.at ? $0.order < $1.order : $0.entry.at < $1.entry.at }

        // The same write recorded again, with nothing between them, is the one entry.
        var entries: [TimelineEntry] = []
        for draft in drafts {
            if let last = entries.indices.last, draft.slot == nil, entries[last].kind != .pause, entries[last].sameWrite(as: draft.entry) {
                entries[last].eventIDs += draft.entry.eventIDs
                entries[last].isNew = entries[last].isNew || draft.entry.isNew
            } else {
                entries.append(draft.entry)
            }
        }
        return entries.map { entry in
            guard entry.kind == .pause else { return entry }
            var entry = entry
            entry.durationSeconds = max(Int((entry.endedAt ?? reference).timeIntervalSince(entry.at)), 0)
            return entry
        }
    }

    /// The rule actions that fold into the entry they caused: a pause they set or lifted, a move they made.
    static let ruleCauses: Set<String> = ["paused", "lifted_pause", "moved"]

    /// A phase entered beside a person's move to it, and a person's action beside the move it made, are that move:
    /// the move with the person keeps them all.
    private static func foldMoves(_ drafts: [Draft]) -> [Draft] {
        var drafts = drafts
        var removed = Set<Int>()
        for index in drafts.indices {
            guard let target = drafts[index].target else { continue }
            let rank = moveRank(drafts[index].type)
            let keeper = drafts.indices.first { other in
                other != index && !removed.contains(other) && drafts[other].target == target && moveRank(drafts[other].type) > rank
                    && abs(drafts[other].entry.at.timeIntervalSince(drafts[index].entry.at)) <= causeWindow
            }
            guard let keeper else { continue }
            drafts[keeper].entry.eventIDs += drafts[index].entry.eventIDs
            drafts[keeper].entry.isNew = drafts[keeper].entry.isNew || drafts[index].entry.isNew
            if drafts[keeper].entry.detail == nil { drafts[keeper].entry.detail = drafts[index].entry.detail }
            removed.insert(index)
        }
        return drafts.indices.filter { !removed.contains($0) }.map { drafts[$0] }
    }

    private static func moveRank(_ type: String) -> Int {
        switch type {
        case "ticket.moved": 2
        case "person.action": 1
        default: 0
        }
    }

    static func pauseSlot(_ type: String) -> String? {
        if type.hasPrefix("pause.") { return "pause" }
        if type.hasPrefix("hold.") { return "hold" }
        return nil
    }

    /// An entry being built: what it folded, where its pause set and cleared, the phase its move went to.
    private struct Draft {
        var entry: TimelineEntry
        var type: String
        /// Its place in Symphony's order, to keep events of one moment as they came.
        var order: Int
        var slot: String?
        var moments: [Date]
        var target: String?

        init(_ event: TicketEventsPayload.Event, at: Date, order: Int, kind: TimelineEntry.Kind, actor: String) {
            entry = TimelineEntry(
                id: event.id, kind: kind, at: at, title: event.summary?.title?.trimmedNonEmpty ?? event.type,
                detail: event.summary?.detail?.trimmedNonEmpty, actor: actor, isNew: event.isNew
            )
            type = event.type
            self.order = order
            moments = [at]
            let moves = event.type == "phase.entered" || event.type == "ticket.moved" || event.type == "person.action"
            target = moves ? event.payload.to?.trimmedNonEmpty : nil
        }

        /// Takes in `event`, written at `at`; `also` adds a reason the entry didn't say yet to its detail.
        mutating func fold(_ event: TicketEventsPayload.Event, at: Date, also: String? = nil) {
            entry.eventIDs.append(event.id)
            entry.isNew = entry.isNew || event.isNew
            moments.append(at)
            guard let also, also != entry.title, !(entry.detail ?? "").contains(also) else { return }
            entry.detail = [entry.detail, also].compactMap { $0 }.joined(separator: "\n")
        }
    }

    // MARK: - Classes and actors

    static let symphony = "Symphony"

    static func kind(_ event: TicketEventsPayload.Event) -> TimelineEntry.Kind {
        switch event.type {
        case "phase.entered", "ticket.moved", "ticket.cancelled", "drift.detected", "drift.reverted", "drift.revert_failed":
            return .phase
        case "question.asked", "decision.requested", "question.reopened": return .questionAsked
        case "question.answered", "decision.recorded": return .questionAnswered
        case "question.withdrawn", "decision.withdrawn", "question.not_asked": return .questionClosed
        case "run.started": return .runStarted
        case "run.ended":
            return outcomeKind(TicketEventsPayload.exitState(event.payload.exit).0)
        case "verdict.recorded":
            return outcomeKind(event.payload.outcome.map { TicketEventsPayload.verdictState(kind: event.payload.kind, outcome: $0).0 } ?? .done)
        case "person.action", "run.started_by_person": return .person
        case "rule.action": return .rule
        case "finding.recorded": return .finding
        case "finding.resolved", "finding.confirmed": return .findingResolved
        case "note", "brief.written": return .note
        case "ticket.filed": return .ticket
        case "situation.changed": return .situation
        default: return .other
        }
    }

    static func outcomeKind(_ result: TicketPage.Step.Result) -> TimelineEntry.Kind {
        switch result {
        case .failed: .runFailed
        case .stopped: .runStopped
        case .done, .current: .runPassed
        }
    }

    /// Who did `event`: the rule a `rule.action` names; the person or the run its actor is; the rule, person or run
    /// a pause or a question names as its setter; the run it was recorded for; else Symphony.
    static func actor(_ event: TicketEventsPayload.Event, history: TicketEventsPayload) -> String {
        if event.type == "rule.action" { return ruleName(event) }
        switch event.actor?.kind {
        case "person": return event.actor?.name?.trimmedNonEmpty ?? you
        case "agent": return runName(event.actor?.runId ?? event.runID, kind: event.actor?.runKind, history: history)
        default: break
        }
        if let setter = event.payload.setter {
            switch setter.kind {
            case "rule": return "Rule: " + (setter.name?.trimmedNonEmpty ?? "a rule")
            case "person": return setter.name?.trimmedNonEmpty ?? you
            case "run": return runName(event.runID, kind: setter.name, history: history)
            default: break
            }
        }
        if let runID = event.runID, history.runs[runID] != nil { return runName(runID, kind: nil, history: history) }
        return symphony
    }

    static let you = "You"

    static func ruleName(_ event: TicketEventsPayload.Event) -> String {
        "Rule: " + (event.payload.rule?.trimmedNonEmpty ?? "a rule")
    }

    static func runName(_ runID: String?, kind: String?, history: TicketEventsPayload) -> String {
        if let runID, let run = history.runs[runID] { return TicketEventsPayload.runTitle(kind: run.runKind, number: run.runNumber) }
        return TicketEventsPayload.runTitle(kind: kind, number: nil)
    }
}

extension TimelineEntry {
    /// The same write recorded twice: the same class, words and actor.
    func sameWrite(as other: TimelineEntry) -> Bool {
        kind == other.kind && title == other.title && detail == other.detail && actor == other.actor
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let trimmed = trimmingWhitespace()
        return trimmed.isEmpty ? nil : trimmed
    }
}
