import Foundation

/// Tickets (D6): every ticket Symphony tracks, one row each, from the lists of one `/api/v1/state` payload. Pure, so
/// stages, what each ticket waits on, the scope bar, search and sorting are tested against the fixtures.
public struct TicketList: Equatable {
    /// Where a ticket is in the flow, as the Overview's flow strip names its stages.
    public enum Stage: Int, CaseIterable, Comparable {
        case queued, working, review, waitingOnYou, merging, shipped

        public var title: String {
            switch self {
            case .queued: "Queued"
            case .working: "Working"
            case .review: "Review"
            case .waitingOnYou: "Waiting on you"
            case .merging: "Merging"
            case .shipped: "Shipped"
            }
        }

        public var status: DesignTokens.Status {
            switch self {
            case .queued: .idle
            case .working, .review, .merging: .working
            case .waitingOnYou: .you
            case .shipped: .done
            }
        }

        public static func < (lhs: Stage, rhs: Stage) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// The scope bar's choices, in its order.
    public enum Filter: String, CaseIterable, Equatable {
        case all, working, review, waitingOnYou, merging, queued, needsAttention, forced, shipped

        public var title: String {
            switch self {
            case .all: "All"
            case .working: "Working"
            case .review: "Review"
            case .waitingOnYou: "Waiting on you"
            case .merging: "Merging"
            case .queued: "Queued"
            case .needsAttention: "Needs attention"
            case .forced: "Forced"
            case .shipped: "Shipped today"
            }
        }

        /// The choices shown in the bar itself; the others fold into **More** while the inspector narrows the table.
        public static func bar(inspectorShown: Bool) -> [Filter] {
            inspectorShown ? [.all, .working, .review, .waitingOnYou] : [.all, .working, .review, .waitingOnYou, .merging, .queued, .needsAttention, .forced]
        }

        /// The choices under **More**.
        public static func more(inspectorShown: Bool) -> [Filter] {
            allCases.filter { !bar(inspectorShown: inspectorShown).contains($0) }
        }

        public func matches(_ row: Row) -> Bool {
            switch self {
            case .all: true
            case .working: row.stage == .working
            case .review: row.stage == .review
            case .waitingOnYou: row.stage == .waitingOnYou
            case .merging: row.stage == .merging
            case .queued: row.stage == .queued
            case .needsAttention: row.needsAttention
            case .forced: row.forced
            case .shipped: row.stage == .shipped
            }
        }

        /// The filter a flow strip tile opens Tickets on; nil for Waiting on you, which opens the Inbox.
        public init?(stage: Overview.StageKind) {
            switch stage {
            case .queued: self = .queued
            case .working: self = .working
            case .review: self = .review
            case .waitingOnYou: return nil
            case .merging: self = .merging
            case .shippedToday: self = .shipped
            }
        }
    }

    /// A row of the table (C19), and what the inspector shows of it.
    public struct Row: Equatable, Identifiable {
        public var id: String { identifier }
        public var identifier: String
        public var issueID: String?
        public var title: String?
        public var repoKey: String?
        /// Its Linear state, for example "In Progress".
        public var state: String?
        public var stage: Stage
        /// What it waits on: "retry at 14:05", "a slot", "BIL-206", "CI", "you".
        public var waitsOn: String
        /// Since when it is where it is; nil when Symphony didn't say.
        public var since: Date?
        /// "3 h", from Symphony's clock.
        public var sinceText: String = ""
        public var forced: Bool
        /// Stuck, failing, routed to more than one repo, or forced for too long.
        public var needsAttention: Bool
        public var url: URL?
        /// The inspector's facts, in order.
        public var facts: [Fact]

        /// Values the table sorts on, never optional.
        public var titleText: String { title ?? "" }
        public var repoText: String { repoKey ?? "" }
        public var sinceSort: Date { since ?? .distantFuture }

        /// One element for VoiceOver: "SHOP-301, Checkout total, Working, waits on the agent, 3 h".
        public var accessibilityLabel: String {
            [identifier, title, stage.title, forced ? "forced" : nil, needsAttention ? "needs attention" : nil, "waits on \(waitsOn)", sinceText.isEmpty ? nil : sinceText]
                .compactMap { $0 }
                .joined(separator: ", ")
        }
    }

    /// A label and value of the inspector.
    public struct Fact: Equatable {
        public var label: String
        public var value: String

        public init(label: String, value: String) {
            self.label = label
            self.value = value
        }
    }

    public static let searchPrompt = "Ticket, title, repo or what it waits on"
    public static let emptyTitle = "No tickets here."
    public static let noMatchTitle = "No tickets match."
    public static let forceTitle = "Force…"
    public static let stopForcingTitle = "Stop Forcing"
    public static let openTitle = "Open Ticket"

    /// Every tracked ticket in the repo scope, by stage then oldest first.
    public var rows: [Row]

    /// The rows of `state` in `scope`. Ages are measured against Symphony's own clock (`generated_at`), `now` only
    /// when the state has none; clock times are in `timeZone`.
    public init(state: OverviewState, scope: OverviewScope = .all, now: Date, timeZone: TimeZone = .current) {
        let reference = state.generatedAt ?? now
        var builder = Builder(reference: reference, timeZone: timeZone)
        let forcedByID = Dictionary(state.snapshot.forced.map { ($0.identifier, $0) }, uniquingKeysWith: { first, _ in first })
        let landingIDs = Set(state.landing)
        let qaIDs = Set(state.qaRunning + state.qaQueued)

        for conflict in state.conflicts {
            builder.add(Row(
                identifier: conflict.identifier, title: conflict.title, repoKey: conflict.repoKeys.first, stage: .queued,
                waitsOn: "one repo label", since: nil, forced: false, needsAttention: true, url: conflict.url,
                facts: [Fact(label: "Problem", value: "Routed to \(conflict.repoKeys.joined(separator: ", ")), so it runs in none")]
            ))
        }
        for run in state.running {
            let landing = run.issueID.map(landingIDs.contains) == true || Self.isState(run.state, "Merging")
            let idle = run.lastEventAt.map { Int(reference.timeIntervalSince($0)) }
            let stuck = !landing && (idle ?? 0) >= Int(Overview.stuckAfter)
            var facts = [Fact(label: "Run", value: landing ? "Landing" : run.runKind.map(Overview.phaseName) ?? "Agent run")]
            if run.turnCount > 0 { facts.append(Fact(label: "Turn", value: "\(run.turnCount)")) }
            if let idle { facts.append(Fact(label: "Last activity", value: "\(Overview.duration(idle)) ago")) }
            if run.totalTokens > 0 { facts.append(Fact(label: "Tokens", value: Overview.tokens(run.totalTokens))) }
            if let message = run.lastMessage { facts.append(Fact(label: "Last message", value: message)) }
            builder.add(Row(
                identifier: run.identifier, issueID: run.issueID, title: run.title, repoKey: run.repoKey, state: run.state,
                stage: landing ? .merging : .working, waitsOn: landing ? "landing" : stuck ? "a stuck run" : "the agent",
                since: run.startedAt, forced: false, needsAttention: stuck, url: run.url, facts: facts
            ))
        }
        for item in state.snapshot.waitingOnYou {
            builder.add(Row(
                identifier: item.identifier, issueID: item.issueID, title: item.title, repoKey: item.repoKey, state: nil,
                stage: .waitingOnYou, waitsOn: "you", since: item.waitingSeconds.map { reference.addingTimeInterval(-Double($0)) },
                forced: false, needsAttention: false, url: item.url,
                facts: item.headline.map { [Fact(label: "Asks", value: $0)] } ?? []
            ))
        }
        for ticket in state.watching {
            let stage: Stage
            let waitsOn: String
            if Self.isState(ticket.state, "Human Review") {
                (stage, waitsOn) = (.waitingOnYou, "you")
            } else if Self.isState(ticket.state, "Merging") {
                (stage, waitsOn) = (.merging, "CI")
            } else {
                let qa = ticket.issueID.map(qaIDs.contains) == true || Self.isState(ticket.state, "QA")
                (stage, waitsOn) = (.review, qa ? "a QA pass" : "the reviewer")
            }
            builder.add(Row(
                identifier: ticket.identifier, issueID: ticket.issueID, title: ticket.title, repoKey: ticket.repoKey,
                state: ticket.state, stage: stage, waitsOn: waitsOn,
                since: ticket.secondsSinceLastRun.map { reference.addingTimeInterval(-Double($0)) },
                forced: false, needsAttention: false, url: ticket.url, facts: []
            ))
        }
        for entry in state.autoMerge {
            builder.add(Row(
                identifier: entry.identifier, issueID: entry.issueID, title: nil, repoKey: nil, state: nil, stage: .merging,
                waitsOn: entry.state == "enabled" || entry.state == nil ? "CI" : entry.state.map(Self.words) ?? "CI",
                since: entry.updatedAt, forced: false, needsAttention: entry.state == "conflict" || entry.state == "ci_failure",
                url: nil, facts: entry.status.map { [Fact(label: "Auto-merge", value: $0)] } ?? []
            ))
        }
        for waiting in state.slotWaiting {
            let merging = Self.isState(waiting.state, "Merging")
            builder.add(Row(
                identifier: waiting.identifier, issueID: waiting.issueID, title: waiting.title, repoKey: waiting.repoKey,
                state: waiting.state, stage: merging ? .merging : .queued, waitsOn: merging ? "CI" : "a slot",
                since: waiting.since, forced: false, needsAttention: false, url: nil,
                facts: waiting.reason.map { [Fact(label: "Why", value: $0)] } ?? []
            ))
        }
        for retry in state.retrying {
            let when = retry.dueAt.map { "retry at \(StatusMenu.clockTime($0, now: reference, timeZone: timeZone, dateFormat: "MMM d HH:mm"))" }
            var facts = [Fact(label: "Failed attempts", value: "\(retry.attempt)")]
            if let error = retry.error { facts.append(Fact(label: "Last error", value: error)) }
            builder.add(Row(
                identifier: retry.identifier, issueID: retry.issueID, title: retry.title, repoKey: retry.repoKey, state: nil,
                stage: .queued, waitsOn: when ?? "a retry", since: nil, forced: false,
                needsAttention: retry.attempt >= Overview.failedAttemptsLimit, url: nil, facts: facts
            ))
        }
        for blocked in state.blocked {
            let waitsOn = blocked.blockers.isEmpty ? (blocked.reason.map { _ in "an app update" } ?? "its blockers") : blocked.blockers.joined(separator: ", ")
            builder.add(Row(
                identifier: blocked.identifier, issueID: blocked.issueID, title: blocked.title, repoKey: nil, state: blocked.state,
                stage: .queued, waitsOn: waitsOn, since: nil, forced: false, needsAttention: false, url: nil,
                facts: blocked.reason.map { [Fact(label: "Why", value: $0)] } ?? []
            ))
        }
        for forced in state.snapshot.forced {
            let running = forced.summary?.contains("running") == true
            builder.add(Row(
                identifier: forced.identifier, title: nil, repoKey: nil, state: forced.state,
                stage: running ? .working : .queued, waitsOn: forced.summary.map(Self.forcedWaitsOn) ?? "a forced slot",
                since: forced.forcedForSeconds.map { reference.addingTimeInterval(-Double($0)) }, forced: true,
                needsAttention: forced.stale, url: nil, facts: []
            ))
        }
        for ticket in state.shippedToday {
            builder.add(Row(
                identifier: ticket.identifier, issueID: ticket.issueID, title: ticket.title, repoKey: ticket.repoKey, state: "Done",
                stage: .shipped, waitsOn: "nothing", since: ticket.completedAt, forced: false, needsAttention: false,
                url: ticket.url, facts: []
            ))
        }

        // Each ticket's forced facts, whichever list it came from.
        rows = builder.rows
            .map { row in
                var row = row
                if let forced = forcedByID[row.identifier] {
                    row.forced = true
                    row.needsAttention = row.needsAttention || forced.stale
                    if let summary = forced.summary { row.facts.append(Fact(label: "Forced status", value: summary)) }
                    if let part = forced.part { row.facts.append(Fact(label: "Working through", value: part)) }
                }
                row.sinceText = row.since.map { Overview.duration(Int(reference.timeIntervalSince($0))) } ?? ""
                row.facts = Self.facts(row) + row.facts
                return row
            }
            .filter { scope.includes($0.repoKey) }
            .sorted(by: Self.defaultOrder)
    }

    /// The rows the scope bar and the search show.
    public func rows(filter: Filter, search: String) -> [Row] {
        let words = search.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        return rows.filter { row in
            guard filter.matches(row) else { return false }
            let text = [row.identifier, row.titleText, row.repoText, row.waitsOn, row.stage.title].joined(separator: " ").lowercased()
            return words.allSatisfy(text.contains)
        }
    }

    /// How many rows each choice of the scope bar shows, for its labels.
    public func count(_ filter: Filter) -> Int { rows.filter(filter.matches).count }

    /// The default order, then the columns' comparators, as the table sorts.
    public static let defaultSort = [KeyPathComparator(\Row.stage), KeyPathComparator(\Row.sinceSort)]

    /// The row of `identifier`, case-insensitively.
    public func row(_ identifier: String) -> Row? {
        rows.first { $0.identifier.caseInsensitiveCompare(identifier) == .orderedSame }
    }

    // MARK: - Helpers

    private struct Builder {
        let reference: Date
        let timeZone: TimeZone
        var rows: [Row] = []
        private var index: [String: Int] = [:]

        init(reference: Date, timeZone: TimeZone) {
            self.reference = reference
            self.timeZone = timeZone
        }

        /// The first list a ticket shows in decides its stage; later lists only fill in what it lacks.
        mutating func add(_ row: Row) {
            guard let at = index[row.identifier] else {
                index[row.identifier] = rows.count
                rows.append(row)
                return
            }
            var existing = rows[at]
            existing.issueID = existing.issueID ?? row.issueID
            existing.title = existing.title ?? row.title
            existing.repoKey = existing.repoKey ?? row.repoKey
            existing.state = existing.state ?? row.state
            existing.url = existing.url ?? row.url
            existing.since = existing.since ?? row.since
            existing.needsAttention = existing.needsAttention || row.needsAttention
            existing.facts += row.facts
            rows[at] = existing
        }
    }

    private static func facts(_ row: Row) -> [Fact] {
        var facts = [Fact(label: "Stage", value: row.stage.title)]
        if let state = row.state { facts.append(Fact(label: "State", value: state)) }
        if let repo = row.repoKey { facts.append(Fact(label: "Repo", value: repo)) }
        facts.append(Fact(label: "Waits on", value: row.waitsOn))
        if !row.sinceText.isEmpty { facts.append(Fact(label: "Since", value: "\(row.sinceText) ago")) }
        facts.append(Fact(label: "Forced", value: row.forced ? "Yes" : "No"))
        return facts
    }

    /// Stage by stage, then the oldest first, then by identifier.
    private static func defaultOrder(_ lhs: Row, _ rhs: Row) -> Bool {
        if lhs.stage != rhs.stage { return lhs.stage < rhs.stage }
        if lhs.sinceSort != rhs.sinceSort { return lhs.sinceSort < rhs.sinceSort }
        return lhs.identifier.localizedStandardCompare(rhs.identifier) == .orderedAscending
    }

    /// "implementation · waiting on blocker TP-1" → "blocker TP-1"; "waiting for a human" → "a human".
    static func forcedWaitsOn(_ summary: String) -> String {
        let last = summary.components(separatedBy: " · ").last ?? summary
        for prefix in ["waiting on ", "waiting for "] where last.hasPrefix(prefix) {
            return String(last.dropFirst(prefix.count))
        }
        return last == "running" ? "the agent" : last
    }

    /// "ci_failure" → "ci failure".
    private static func words(_ text: String) -> String {
        text.replacingOccurrences(of: "_", with: " ")
    }

    private static func isState(_ state: String?, _ name: String) -> Bool {
        state?.trimmingWhitespace().caseInsensitiveCompare(name) == .orderedSame
    }
}
