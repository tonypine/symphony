import Foundation

/// The dispatch order (`docs/control-api.md` § The dispatch order): `order` on `GET /api/v1/state`, and
/// `GET /api/v1/dispatch/order`. Every open ticket Symphony works, grouped by the kind of its situation in the
/// situation's precedence, and the candidates in the order the dispatcher starts them, each with the reason it is or is
/// not next. Symphony computes it on the poll's triggers; the app only reads it.
public struct DispatchOrder: Equatable {
    /// What a pass run now would do with the ticket.
    public enum Outcome: String, Equatable {
        /// It starts: a slot is free, or it is forced.
        case starts
        /// It waits for a slot.
        case waits
        /// Its gates are open, but the whole pass is paused.
        case paused
        /// A gate keeps it out of the pass.
        case held
        /// A run works on it.
        case running
        /// An open ticket the poll does not offer for dispatch.
        case notACandidate = "not_a_candidate"
    }

    public struct Ticket: Equatable {
        public var issueID: String?
        public var identifier: String
        public var title: String?
        public var state: String?
        public var repoKey: String?
        public var outcome: Outcome?
        /// Its place in line, 1 for the next one; nil for one that is not in line.
        public var position: Int?
        /// "next: a slot is free", "2nd: behind TP-1401", "forced", the pause's line, the gate's reason.
        public var reason: String?
        public var forced: Bool
        public var situation: Situation?

        public init(
            issueID: String? = nil, identifier: String, title: String? = nil, state: String? = nil, repoKey: String? = nil,
            outcome: Outcome? = nil, position: Int? = nil, reason: String? = nil, forced: Bool = false, situation: Situation? = nil
        ) {
            self.issueID = issueID
            self.identifier = identifier
            self.title = title
            self.state = state
            self.repoKey = repoKey
            self.outcome = outcome
            self.position = position
            self.reason = reason
            self.forced = forced
            self.situation = situation
        }
    }

    public struct Group: Equatable {
        public var kind: DesignTokens.SituationKind
        public var tickets: [Ticket]

        public init(kind: DesignTokens.SituationKind, tickets: [Ticket]) {
            self.kind = kind
            self.tickets = tickets
        }
    }

    public var computedAt: Date?
    /// The identifier of the ticket first in line.
    public var next: String?
    public var groups: [Group]

    public init(computedAt: Date? = nil, next: String? = nil, groups: [Group] = []) {
        self.computedAt = computedAt
        self.next = next
        self.groups = groups
    }

    /// The order in a `/state` payload (its `order`) or a `/dispatch/order` one (the payload itself); nil when there is
    /// none, as from a Symphony that predates it or one that couldn't be read.
    public static func decode(_ data: Data) -> DispatchOrder? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return decode(object: (root["order"] as? [String: Any]) ?? root)
    }

    static func decode(object: [String: Any]) -> DispatchOrder? {
        guard let groups = object["groups"] as? [[String: Any]] else { return nil }
        return DispatchOrder(
            computedAt: (object["computed_at"] as? String).flatMap(SymphonyState.parseDate),
            next: object["next"] as? String,
            groups: groups.compactMap { group in
                guard let kind = (group["kind"] as? String).flatMap(DesignTokens.SituationKind.init(apiKind:)) else { return nil }
                return Group(kind: kind, tickets: (group["tickets"] as? [[String: Any]] ?? []).compactMap(ticket))
            }
        )
    }

    private static func ticket(_ entry: [String: Any]) -> Ticket? {
        guard let identifier = (entry["identifier"] ?? entry["issue_identifier"]) as? String else { return nil }
        return Ticket(
            issueID: entry["issue_id"] as? String,
            identifier: identifier,
            title: entry["title"] as? String,
            state: entry["state"] as? String,
            repoKey: entry["repo_key"] as? String,
            outcome: (entry["outcome"] as? String).flatMap(Outcome.init(rawValue:)),
            position: entry["position"] as? Int,
            reason: entry["reason"] as? String,
            forced: entry["forced"] as? Bool ?? false,
            situation: Situation.decode(object: entry["situation"])
        )
    }
}

/// Home (D1): the board of every open ticket Symphony works, grouped by situation kind in the precedence of
/// `director-ticket-page.md` §3, each group's tickets in the order the dispatcher would start them, from the dispatch
/// order alone. Every count on it is a count of the rows it shows, so a count never disagrees with the board.
public struct HomeBoard: Equatable {
    /// A ticket's row: its compact situation line and age, the Forced chip, and for a ticket in line or held out of
    /// it, why it is or is not next.
    public struct Row: Equatable, Identifiable {
        public var identifier: String
        public var title: String?
        public var repoKey: String?
        public var situation: Situation
        public var forced: Bool
        /// The secondary line: "Next: a slot is free", "2nd: behind TP-1401", "Not next: dispatch is paused."; nil for
        /// a ticket that is not a candidate, a running one, or one whose reason is its situation's cause.
        public var reason: String?

        public var id: String { identifier }

        public init(identifier: String, title: String? = nil, repoKey: String? = nil, situation: Situation, forced: Bool = false, reason: String? = nil) {
            self.identifier = identifier
            self.title = title
            self.repoKey = repoKey
            self.situation = situation
            self.forced = forced
            self.reason = reason
        }

        /// What VoiceOver reads for the row: "SHOP-301, Checkout total, web-shop, Waiting for a slot, for 6 minutes:
        /// Both work slots are taken. Next: work slots full".
        public func accessibilityLabel(reference: Date) -> String {
            let line = SituationText(situation, reference: reference).spoken(forced: forced)
            return ([identifier, title, repoKey].compactMap { $0 } + [line] + [reason].compactMap { $0 }).joined(separator: ", ")
        }
    }

    public struct Group: Equatable, Identifiable {
        public var kind: DesignTokens.SituationKind
        public var rows: [Row]
        /// "oldest 3 h 12 min", "longest 1 h"; nil when empty or when no row says since when.
        public var hint: String?

        public var id: DesignTokens.SituationKind { kind }
        /// The heading's count: the rows the group shows.
        public var count: Int { rows.count }
        public var isEmpty: Bool { rows.isEmpty }
        public var title: String { HomeBoard.title(kind) }

        /// "Waiting for a slot, 5" or "Retrying, none right now".
        public var accessibilityLabel: String {
            isEmpty ? "\(title), \(HomeBoard.emptyHint.lowercased())" : "\(title), \(count)"
        }
    }

    /// The kinds Home always shows, empty or not, in their precedence. Shipped and Cancelled join only with rows.
    public static let kinds: [DesignTokens.SituationKind] = [.you, .retrying, .blocked, .paused, .ci, .build, .slot, .working]
    public static let emptyHint = "None right now"
    public static let readingOrder = "Reading the dispatch order…"
    public static let olderSymphony = "Update Symphony to see the board: this one doesn't serve its dispatch order."

    public var groups: [Group]
    /// Symphony's clock when it took the state, which the rows' ages are measured against.
    public var reference: Date
    /// Whether the state carried the dispatch order; a Symphony that predates it shows `olderSymphony`.
    public var hasOrder: Bool
    /// While dispatch is paused, the sentence that says so, or while only a usage limit holds runs `heldSentence`;
    /// nil otherwise.
    public var pauseSentence: String?
    /// The Director's pause or an update's holds dispatch, which Resume Dispatch lifts.
    public var dispatchPaused: Bool
    /// The paused usage-limit hold the notice offers **Try Now** for, nil when none is paused.
    public var tryNow: StateSnapshot.UsageLimit?
    /// Under it: one line per reason of Symphony's pause, then "All repositories paused" when every repository is.
    public var pauseLines: [String]
    /// An update is under way: it resumes the dispatch it paused, or Cancel Update does.
    public var updating: Bool

    /// The sentence offers Resume Dispatch while dispatch is paused, unless an update holds it.
    public var showsResume: Bool { dispatchPaused && pauseSentence != nil && !updating }
    /// The notice offers Try Now while a usage limit is paused: Symphony checks it with one held run.
    public var showsTryNow: Bool { pauseSentence != nil && tryNow != nil }

    /// The notice's sentence while no pause of the Director's or an update's holds dispatch, but a usage limit holds
    /// new runs.
    public static let heldSentence = "New runs are held."
    /// Every row, top to bottom, which the arrow keys walk.
    public var rowIDs: [String] { groups.flatMap { $0.rows.map(\.identifier) } }
    /// The rows of the whole board: the sum of the groups' counts.
    public var count: Int { groups.reduce(0) { $0 + $1.count } }

    /// The board of `state` under `scope`. Ages are measured against Symphony's own clock (`generated_at`), `now` only
    /// when the state has none.
    public init(state: OverviewState, scope: OverviewScope = .all, updating: Bool = false, now: Date, timeZone: TimeZone = .current) {
        let reference = state.generatedAt ?? now
        self.reference = reference
        self.updating = updating
        hasOrder = state.order != nil
        groups = Self.groups(state.order, scope: scope, reference: reference)

        pauseLines = []
        let holds = state.snapshot.usageLimits.filter { $0.phase != .canary }
        tryNow = holds.first(where: \.canTryNow)
        dispatchPaused = state.snapshot.pause != nil
        if let pause = state.snapshot.pause {
            if let reasons = state.snapshot.pauseReasons {
                pauseSentence = "Dispatch is paused."
                pauseLines = StatusMenu.pauseReasonLines(reasons, now: reference, timeZone: timeZone)
            } else {
                pauseSentence = Overview.pauseSentence(pause, reference: reference, timeZone: timeZone)
            }
        } else if !holds.isEmpty {
            pauseSentence = Self.heldSentence
            pauseLines = holds.map { StatusMenu.usageLimitLine($0, now: reference, timeZone: timeZone) }
        } else {
            pauseSentence = nil
        }
        if state.snapshot.allRepositoriesPaused { pauseLines.append(StatusMenu.allRepositoriesPausedLine) }
    }

    /// One group per kind Home shows, then any other kind the order holds, each ticket once.
    static func groups(_ order: DispatchOrder?, scope: OverviewScope, reference: Date) -> [Group] {
        var byKind: [DesignTokens.SituationKind: [Row]] = [:]
        var seen = Set<String>()
        for group in order?.groups ?? [] {
            for ticket in group.tickets where scope.includes(ticket.repoKey) && seen.insert(ticket.identifier).inserted {
                let situation = ticket.situation ?? Situation(kind: group.kind, cause: ticket.reason ?? "")
                byKind[group.kind, default: []].append(Row(
                    identifier: ticket.identifier, title: ticket.title, repoKey: ticket.repoKey, situation: situation,
                    forced: ticket.forced, reason: reasonLine(ticket, cause: situation.cause)
                ))
            }
        }
        return DesignTokens.SituationKind.allCases
            .filter { kinds.contains($0) || byKind[$0] != nil }
            .map { kind in
                let rows = byKind[kind] ?? []
                return Group(kind: kind, rows: rows, hint: hint(kind, rows: rows, reference: reference))
            }
    }

    /// The group's heading: the kind's word, "Blocked by a ticket" and "Paused by a rule" spelled out.
    public static func title(_ kind: DesignTokens.SituationKind) -> String {
        switch kind {
        case .blocked: "Blocked by a ticket"
        case .paused: "Paused by a rule"
        default: kind.word
        }
    }

    /// The heading's hint: how long the longest-running has worked, or the oldest has waited.
    static func hint(_ kind: DesignTokens.SituationKind, rows: [Row], reference: Date) -> String? {
        let oldest = rows.compactMap { $0.situation.since.map { Int(reference.timeIntervalSince($0)) } }.max()
        guard let oldest, kind != .done, kind != .cancelled else { return nil }
        return (kind == .working ? "longest " : "oldest ") + Overview.duration(oldest)
    }

    /// Why a candidate is or is not next, as its secondary line; nil for a ticket that is not one or runs, and for a
    /// reason that only repeats the situation's cause.
    public static func reasonLine(_ ticket: DispatchOrder.Ticket, cause: String) -> String? {
        guard let outcome = ticket.outcome, let reason = ticket.reason?.trimmingWhitespace(), !reason.isEmpty else { return nil }
        switch outcome {
        case .running, .notACandidate:
            return nil
        case .starts where ticket.forced && reason == "forced":
            return "Next: forced, it starts on its own allowance"
        case .starts, .waits:
            return capitalized(reason)
        case .paused, .held:
            guard normalized(reason) != normalized(cause) else { return nil }
            return "Not next: " + reason
        }
    }

    /// The row the arrow keys land on from `id`: `offset` rows on, across groups, staying at the ends. With no row
    /// picked yet, Down picks the first and Up the last.
    public func row(from id: String?, offset: Int) -> String? {
        let ids = rowIDs
        guard !ids.isEmpty else { return nil }
        guard let id, let index = ids.firstIndex(of: id) else { return offset < 0 ? ids.last : ids.first }
        return ids[min(max(index + offset, 0), ids.count - 1)]
    }

    private static func capitalized(_ text: String) -> String {
        text.prefix(1).uppercased() + text.dropFirst()
    }

    private static func normalized(_ text: String) -> String {
        var text = text.trimmingWhitespace().lowercased()
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}
