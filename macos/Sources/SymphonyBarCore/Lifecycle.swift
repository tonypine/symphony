import Foundation

// The ticket read's `lifecycle` and `phase_path` (`docs/control-api.md` § `lifecycle`, § `phase_path`) and what the
// Lifecycle section and the Phase path component say from them (`docs/design/director-ticket-page.md` §1 facts 7, 19
// and 20). Symphony computes both from the ticket's ledger; the app only says them, with the names as served.

/// Where the ticket is on its way to landing: the five stages in order and its tokens against its cap.
public struct TicketLifecycle: Equatable, Decodable {
    /// `paused`: the stage the ticket is in while a pause holds it; `sent_back`: a stage ahead whose verdict sent the
    /// ticket back to Rework, until it enters it again.
    public enum StageState: String, Equatable, Decodable {
        case current, paused, passed, skipped
        case sentBack = "sent_back"
        case notYet = "not_yet"
    }

    public struct Stage: Equatable, Decodable {
        public var id: String
        public var name: String
        public var state: StageState
        public var visits: Int
        public var timeMs: Int
        public var agentTimeMs: Int
        public var tokens: Int
        /// How many runs worked in the stage, the one working now included.
        public var runs: Int

        public init(
            id: String, name: String, state: StageState, visits: Int = 0, timeMs: Int = 0, agentTimeMs: Int = 0, tokens: Int = 0,
            runs: Int = 0
        ) {
            self.id = id
            self.name = name
            self.state = state
            self.visits = visits
            self.timeMs = timeMs
            self.agentTimeMs = agentTimeMs
            self.tokens = tokens
            self.runs = runs
        }

        private enum CodingKeys: String, CodingKey {
            case id, name, state, visits, tokens, runs
            case timeMs = "time_ms", agentTimeMs = "agent_time_ms"
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            name = try container.decodeIfPresent(String.self, forKey: .name) ?? id
            state = try container.decodeIfPresent(StageState.self, forKey: .state) ?? .notYet
            visits = try container.decodeIfPresent(Int.self, forKey: .visits) ?? 0
            timeMs = try container.decodeIfPresent(Int.self, forKey: .timeMs) ?? 0
            agentTimeMs = try container.decodeIfPresent(Int.self, forKey: .agentTimeMs) ?? 0
            tokens = try container.decodeIfPresent(Int.self, forKey: .tokens) ?? 0
            runs = try container.decodeIfPresent(Int.self, forKey: .runs) ?? 0
        }
    }

    public struct Tokens: Equatable, Decodable {
        public var total: Int
        /// The ticket's cap; nil when there is none.
        public var cap: Int?

        public init(total: Int, cap: Int? = nil) {
            self.total = total
            self.cap = cap
        }

        private enum CodingKeys: String, CodingKey { case total, cap }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            total = try container.decodeIfPresent(Int.self, forKey: .total) ?? 0
            cap = try container.decodeIfPresent(Int.self, forKey: .cap)
        }
    }

    /// The id of the stage the ticket is in; nil outside the stages and once it is Done.
    public var current: String?
    public var stages: [Stage]
    public var tokens: Tokens

    public init(current: String?, stages: [Stage], tokens: Tokens) {
        self.current = current
        self.stages = stages
        self.tokens = tokens
    }

    private enum CodingKeys: String, CodingKey { case current, stages, tokens }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        current = try container.decodeIfPresent(String.self, forKey: .current)
        stages = try container.decodeIfPresent([Stage].self, forKey: .stages) ?? []
        tokens = try container.decodeIfPresent(Tokens.self, forKey: .tokens) ?? Tokens(total: 0)
    }
}

/// The phases the ticket went through, in the order it first entered each, and every move with its time.
public struct TicketPhasePath: Equatable, Decodable {
    public struct Phase: Equatable, Decodable {
        public var phase: String
        public var count: Int
        public var timeMs: Int
        public var firstEnteredAt: Date?

        public init(phase: String, count: Int = 1, timeMs: Int = 0, firstEnteredAt: Date? = nil) {
            self.phase = phase
            self.count = count
            self.timeMs = timeMs
            self.firstEnteredAt = firstEnteredAt
        }

        private enum CodingKeys: String, CodingKey {
            case phase, count
            case timeMs = "time_ms", firstEnteredAt = "first_entered_at"
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            phase = try container.decode(String.self, forKey: .phase)
            count = try container.decodeIfPresent(Int.self, forKey: .count) ?? 1
            timeMs = try container.decodeIfPresent(Int.self, forKey: .timeMs) ?? 0
            firstEnteredAt = try container.decodeIfPresent(String.self, forKey: .firstEnteredAt).flatMap(SymphonyState.parseDate)
        }
    }

    public struct Move: Equatable, Decodable {
        public var from: String?
        public var to: String
        public var at: Date?

        public init(from: String? = nil, to: String, at: Date? = nil) {
            self.from = from
            self.to = to
            self.at = at
        }

        private enum CodingKeys: String, CodingKey { case from, to, at }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            from = try container.decodeIfPresent(String.self, forKey: .from)
            to = try container.decode(String.self, forKey: .to)
            at = try container.decodeIfPresent(String.self, forKey: .at).flatMap(SymphonyState.parseDate)
        }
    }

    /// The phase the ticket is in, as its last move names it; nil before any.
    public var current: String?
    public var phases: [Phase]
    public var moves: [Move]

    public init(current: String?, phases: [Phase], moves: [Move] = []) {
        self.current = current
        self.phases = phases
        self.moves = moves
    }

    private enum CodingKeys: String, CodingKey { case current, phases, moves }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        current = try container.decodeIfPresent(String.self, forKey: .current)
        phases = try container.decodeIfPresent([Phase].self, forKey: .phases) ?? []
        moves = try container.decodeIfPresent([Move].self, forKey: .moves) ?? []
    }
}

/// A ticket read's `lifecycle` and `phase_path`, each nil when the read holds none (an older Symphony).
public struct TicketLifecycleRead: Equatable, Decodable {
    public var lifecycle: TicketLifecycle?
    public var phasePath: TicketPhasePath?

    public init(lifecycle: TicketLifecycle?, phasePath: TicketPhasePath?) {
        self.lifecycle = lifecycle
        self.phasePath = phasePath
    }

    private enum CodingKeys: String, CodingKey {
        case lifecycle
        case phasePath = "phase_path"
    }

    /// The two fields of a ticket read (`GET /api/v1/:issue_identifier`); nil for anything but a JSON object.
    public static func decode(_ data: Data) -> TicketLifecycleRead? {
        try? JSONDecoder().decode(TicketLifecycleRead.self, from: data)
    }
}

// MARK: - The Lifecycle section

/// What the Lifecycle section says: where the ticket is, its five stages each with its state, visits and time, and
/// one token bar against the ticket's cap split by the same stages.
public struct LifecycleModel: Equatable {
    public struct Stage: Equatable, Identifiable {
        public var id: String
        /// The stage's name.
        public var title: String
        public var state: TicketLifecycle.StageState
        /// "Passed", "Now", "Paused", "Sent back", "Skipped", "Not yet".
        public var word: String
        /// "Paused · 4 times · 1 h 30 min", "Sent back · 19 min": the word, the visits when more than one, and its time.
        public var line: String
        public var status: DesignTokens.Status
        public var accessibilityLabel: String

        /// A stage as said elsewhere than the ticket page: the Home queue's slot card says its stages with their word
        /// alone, without visits and time (TP-1608).
        public init(
            id: String, title: String, state: TicketLifecycle.StageState, word: String, line: String, status: DesignTokens.Status,
            accessibilityLabel: String
        ) {
            self.id = id
            self.title = title
            self.state = state
            self.word = word
            self.line = line
            self.status = status
            self.accessibilityLabel = accessibilityLabel
        }
    }

    public struct Segment: Equatable, Identifiable {
        public var id: String
        public var name: String
        public var tokens: Int
        /// "2.4M".
        public var value: String
        /// The chart series the stage is drawn in; nil for the Conductor's segment, which takes the accent.
        public var series: DesignTokens.ChartSeries?
        /// The Conductor's own segment: its runs' tokens, apart from the stages'.
        public var isConductor: Bool { series == nil }
    }

    /// One token bar: the stages fill the ticket's cap from the left and the rest stays empty.
    public struct TokenBar: Equatable {
        public var segments: [Segment]
        public var total: Int
        public var cap: Int?
        /// The cap's share used, from 0; nil without a cap.
        public var fraction: Double?
        /// accent below 75 %, `status.you` from 75 %, `status.problem` from 95 % (C11).
        public var level: Overview.Meter.Level
        /// "3.6M of 8M tokens · 45 %", "3.6M tokens in all", "Nothing yet".
        public var value: String
        /// What the cap means now, in words; nil without a cap, and once the ticket ended: it spends nothing more.
        public var note: String?
        public var accessibilityLabel: String

        /// The share of the bar's width each segment takes, then what is left: the cap, or the total past it.
        public var scale: Int { max(total, cap ?? 0) }
    }

    /// One sentence: "In Coding, the 3rd time: QA sent it back, and it waits on your answer", "Done: merged as PR #741
    /// at 21:05", "Not started yet".
    public var whereLine: String
    /// "1 h 50 min of work in 7 runs", "No run yet".
    public var summary: String
    /// True while a stage is current: its dot works.
    public var live: Bool
    public var stages: [Stage]
    public var tokens: TokenBar

    /// The section from `lifecycle`, said in one sentence with the phase path (`path`: the phase it is in and the
    /// move that sent it back) and the ticket's `situation` (what it waits on, and how a finished ticket ended).
    public static func build(
        _ lifecycle: TicketLifecycle, path: TicketPhasePath? = nil, situation: Situation? = nil, conductorTokens: Int = 0
    ) -> LifecycleModel {
        let stages = lifecycle.stages.map(stage(of:))
        let current = lifecycle.stages.first { $0.id == lifecycle.current }
        let ended = ended(lifecycle, path: path, situation: situation)
        let agentSeconds = lifecycle.stages.reduce(0) { $0 + $1.agentTimeMs } / 1_000
        let runs = lifecycle.stages.reduce(0) { $0 + $1.runs }
        let summary: String
        if runs > 0 {
            summary = "\(Overview.duration(agentSeconds)) of work in " + (runs == 1 ? "1 run" : "\(runs) runs")
        } else if agentSeconds > 0 {
            summary = "\(Overview.duration(agentSeconds)) of work"
        } else {
            summary = "No run yet"
        }
        return LifecycleModel(
            whereLine: whereLine(lifecycle, current: current, ended: ended, path: path, situation: situation), summary: summary,
            live: current?.state == .current && !ended, stages: stages, tokens: tokenBar(lifecycle, ended: ended, conductorTokens: conductorTokens)
        )
    }

    /// Whether the ticket ended (Done or Cancelled): it spends nothing more.
    static func ended(_ lifecycle: TicketLifecycle, path: TicketPhasePath?, situation: Situation?) -> Bool {
        if let kind = situation?.kind { return kind == .done || kind == .cancelled }
        if let phase = path?.current, PhasePathModel.terminal.contains(phase) { return true }
        return lifecycle.stages.last.map { $0.id == "done" && $0.state == .passed } ?? false
    }

    /// "In Coding, the 3rd time: QA sent it back, and it waits on your answer": where it is, which visit, why it came back
    /// and what it waits on; for a finished ticket, how it ended.
    static func whereLine(
        _ lifecycle: TicketLifecycle, current: TicketLifecycle.Stage?, ended: Bool, path: TicketPhasePath?, situation: Situation?
    ) -> String {
        if ended { return endLine(situation, path: path) }
        guard let current else {
            if lifecycle.stages.contains(where: { $0.visits > 0 }) {
                return path?.current.map { "In \($0), outside the stages" } ?? "Outside the stages"
            }
            return "Not started yet"
        }
        var line = "In \(current.name)" + (current.visits > 1 ? ", the \(ordinal(current.visits)) time" : "")
        let back = current.id == "coding" ? sentBackBy(lifecycle, path: path) : nil
        let waits = situation.flatMap { waitsOn[$0.kind] }
        switch (back, waits) {
        case let (back?, waits?): line += ": \(back) sent it back, and \(waits)"
        case let (back?, nil): line += ": \(back) sent it back"
        case let (nil, waits?): line += ": \(waits)"
        case (nil, nil): break
        }
        return line
    }

    /// What a held ticket waits on, by its situation's kind.
    static let waitsOn: [DesignTokens.SituationKind: String] = [
        .you: "it waits on your answer", .blocked: "it waits on another ticket", .subTickets: "it waits on its sub-tickets",
        .provider: "it waits for you to resume its provider", .paused: "it waits for the pause to lift",
        .ci: "it waits on CI", .build: "it waits on the build", .slot: "it waits for a free slot", .retrying: "it waits to retry",
    ]

    /// The phase whose verdict sent the ticket back: the last move into Rework names it, else the stage that reads sent
    /// back; nil when no stage does.
    static func sentBackBy(_ lifecycle: TicketLifecycle, path: TicketPhasePath?) -> String? {
        guard let stage = lifecycle.stages.last(where: { $0.state == .sentBack }) else { return nil }
        return path?.moves.last(where: { $0.to == "Rework" })?.from ?? stage.name
    }

    /// "Done: merged as PR #741 at 21:05", "Cancelled: you cancelled it; PR #741 was closed", from the situation's cause.
    static func endLine(_ situation: Situation?, path: TicketPhasePath?) -> String {
        let cancelled = situation.map { $0.kind == .cancelled } ?? ["Canceled", "Cancelled"].contains(path?.current ?? "")
        let word = cancelled ? "Cancelled" : "Done"
        guard let cause = situation?.cause.trimmingCharacters(in: .whitespaces), !cause.isEmpty,
              !["It is done.", "It was cancelled."].contains(cause)
        else { return word }
        let sentence = cause.hasSuffix(".") ? String(cause.dropLast()) : cause
        return "\(word): " + sentence.prefix(1).lowercased() + sentence.dropFirst()
    }

    /// "2nd", "3rd", "11th".
    static func ordinal(_ n: Int) -> String {
        let suffix = switch (n % 10, n % 100) {
        case (1, let t) where t != 11: "st"
        case (2, let t) where t != 12: "nd"
        case (3, let t) where t != 13: "rd"
        default: "th"
        }
        return "\(n)\(suffix)"
    }

    static func stage(of stage: TicketLifecycle.Stage) -> Stage {
        let (word, status): (String, DesignTokens.Status) = switch stage.state {
        case .current: ("Now", .working)
        case .paused: ("Paused", .idle)
        case .sentBack: ("Sent back", .you)
        case .passed: ("Passed", .done)
        case .skipped: ("Skipped", .idle)
        case .notYet: ("Not yet", .idle)
        }
        let soFar = stage.state == .current ? " so far" : ""
        var parts = [word]
        if stage.visits > 1 { parts.append("\(stage.visits) times") }
        let seconds = stage.timeMs / 1_000
        if stage.timeMs > 0 { parts.append(Overview.duration(seconds) + soFar) }
        var spoken = [stage.name]
        if stage.visits > 1 { spoken.append("entered \(stage.visits) times") }
        spoken.append(word.lowercased())
        if stage.timeMs > 0 { spoken.append(Overview.spokenDuration(seconds) + soFar) }
        return Stage(
            id: stage.id, title: stage.name, state: stage.state, word: word, line: parts.map(unbroken).joined(separator: " · "), status: status,
            accessibilityLabel: spoken.joined(separator: ", ")
        )
    }

    /// One part of a stage's line kept whole: its spaces don't break, so a narrow tile wraps only at a " · ".
    static func unbroken(_ part: String) -> String {
        part.replacingOccurrences(of: " ", with: "\u{00A0}")
    }

    /// The token bar's title: the ticket's total across all its runs, which the cap measures; a run's own tokens are
    /// on its header in the timeline.
    public static let tokensTitle = TicketPage.ticketTokensLabel

    /// The Conductor's segment of the token bar.
    public static let conductorSegmentID = "conductor"
    public static let conductorName = "Conductor"

    static let series: [String: DesignTokens.ChartSeries] = ["coding": .series1, "code_review": .series2, "qa": .series3, "merging": .series4]

    /// The bar; a ticket that `ended` keeps its bar and totals, without a warning: it spends nothing more.
    static func tokenBar(_ lifecycle: TicketLifecycle, ended: Bool = false, conductorTokens: Int = 0) -> TokenBar {
        // Done takes no tokens: the four working stages fill the bar, in their landing order.
        var segments = lifecycle.stages.compactMap { stage -> Segment? in
            guard let series = series[stage.id] else { return nil }
            return Segment(id: stage.id, name: stage.name, tokens: stage.tokens, value: Overview.tokens(stage.tokens), series: series)
        }
        let total = lifecycle.tokens.total
        // The Conductor's runs have a segment of their own, drawn only when it has tokens. Its tokens are in the ticket's
        // total once: the segment is drawn when the stages' tokens and the Conductor's make up the total, which is when
        // Symphony keeps the Conductor's runs out of the stage they started in. A Symphony that still counts them in
        // that stage has them in the stages already, and a second segment would count them twice.
        let stageTokens = segments.reduce(0) { $0 + $1.tokens }
        if conductorTokens > 0, stageTokens + conductorTokens <= total {
            segments.append(Segment(
                id: conductorSegmentID, name: conductorName, tokens: conductorTokens, value: Overview.tokens(conductorTokens), series: nil
            ))
        }
        let cap = lifecycle.tokens.cap.flatMap { $0 > 0 ? $0 : nil }
        let fraction = cap.map { Double(total) / Double($0) }
        let percent = cap.map { total * 100 / $0 }
        let value: String
        if let cap, let percent {
            value = "\(Overview.tokens(total)) of \(Overview.tokens(cap)) tokens · \(min(percent, 100)) %"
        } else if total > 0 {
            value = "\(Overview.tokens(total)) tokens in all"
        } else {
            value = "Nothing yet"
        }
        let level: Overview.Meter.Level = ended ? .normal : Overview.level(fraction)
        let note: String? = ended ? nil : percent.map { percent in
            if percent >= 100 { return "At the cap: no new run starts." }
            switch level {
            case .atLimit: return "Almost at the cap: the run finishes, the next one waits."
            case .near: return "Getting close: \(100 - percent) % left of the ticket's cap."
            case .normal: return "\(100 - percent) % of the ticket's cap left."
            }
        }
        let split = segments.filter { $0.tokens > 0 }.map { "\($0.name) \($0.value)" }
        let label = [tokensTitle, value] + split + [note].compactMap { $0 }
        return TokenBar(
            segments: segments, total: total, cap: cap, fraction: fraction, level: level, value: value, note: note,
            accessibilityLabel: label.joined(separator: ", ")
        )
    }
}

// MARK: - The Phase path

/// What the Phase path says: the phases the ticket went through in the order it first entered each, with how many
/// times and how long, the time of each move into it, and one line summing the moves.
public struct PhasePathModel: Equatable {
    public enum State: Equatable {
        case passed, current
    }

    public struct Phase: Equatable, Identifiable {
        public var id: String { name }
        public var name: String
        public var count: Int
        /// "×3" when it was entered more than once.
        public var countLabel: String?
        public var state: State
        public var status: DesignTokens.Status
        /// "29 min", "12 min so far"; nil for a terminal phase or none spent.
        public var time: String?
        /// The times of the moves into it, oldest first: "15:23", "Wed 7 Oct 15:23".
        public var entered: [String]
        public var accessibilityLabel: String
    }

    public var phases: [Phase]
    /// "9 moves so far · sent back twice", "14 moves in 23 h 22 min".
    public var summary: String
    public var accessibilityLabel: String { "Phases, in the order the ticket entered them" }

    /// The phases that end a ticket: they take no time and say how long the whole path took.
    static let terminal: Set<String> = ["Done", "Canceled", "Cancelled"]

    /// The path from `phase_path`; move times read in `calendar`, a move on `reference`'s day by its clock alone.
    public static func build(_ path: TicketPhasePath, reference: Date, calendar: Calendar = .current) -> PhasePathModel {
        let ended = path.current.map(terminal.contains) ?? false
        let phases = path.phases.map { phase -> Phase in
            let current = phase.phase == path.current
            let status: DesignTokens.Status = !current ? .done : ended ? .done : phase.phase == "Rework" ? .you : .working
            let seconds = phase.timeMs / 1_000
            let time = phase.timeMs > 0 && !terminal.contains(phase.phase)
                ? Overview.duration(seconds) + (current && !ended ? " so far" : "") : nil
            var entered = path.moves.filter { $0.to == phase.phase }.compactMap(\.at)
            if entered.isEmpty, let first = phase.firstEnteredAt { entered = [first] }
            let clocks = entered.map { clock($0, reference: reference, calendar: calendar) }
            var spoken = [phase.phase]
            if phase.count > 1 { spoken.append("entered \(phase.count) times") }
            if phase.timeMs > 0, !terminal.contains(phase.phase) {
                spoken.append(Overview.spokenDuration(seconds) + (current && !ended ? " so far" : " in all"))
            }
            if current, !ended { spoken.append("now") }
            if !clocks.isEmpty { spoken.append("entered at " + clocks.joined(separator: ", ")) }
            return Phase(
                name: phase.phase, count: phase.count, countLabel: phase.count > 1 ? "×\(phase.count)" : nil,
                state: current ? .current : .passed, status: status, time: time, entered: clocks,
                accessibilityLabel: spoken.joined(separator: ", ")
            )
        }
        return PhasePathModel(phases: phases, summary: summary(path, ended: ended))
    }

    static func summary(_ path: TicketPhasePath, ended: Bool) -> String {
        let count = path.moves.count
        guard count > 0 else { return path.current.map { "In \($0), no move yet" } ?? "No move yet" }
        let moves = count == 1 ? "1 move" : "\(count) moves"
        if ended, let first = path.moves.first?.at, let last = path.moves.last?.at, last > first {
            return "\(moves) in \(Overview.duration(Int(last.timeIntervalSince(first))))"
        }
        if ended { return moves }
        let back = path.moves.filter { $0.to == "Rework" }.count
        let sent = switch back {
        case 0: ""
        case 1: " · sent back once"
        case 2: " · sent back twice"
        default: " · sent back \(back) times"
        }
        return "\(moves) so far" + sent
    }

    /// "15:23" on `reference`'s day, "Wed 7 Oct 15:23" on another.
    static func clock(_ date: Date, reference: Date, calendar: Calendar) -> String {
        let format = calendar.isDate(date, inSameDayAs: reference) ? "HH:mm" : "EEE d MMM HH:mm"
        return SharedDateFormatter.string(date, format: format, locale: SharedDateFormatter.british, calendar: calendar)
    }
}

extension TicketEventsPayload {
    /// The tokens the Conductor's runs spent on the ticket, summed: the `tokens` each of them recorded when it ended.
    public var conductorTokens: Int {
        events.reduce(0) { sum, event in
            guard event.type == "run.ended", let run = event.runID.flatMap({ runs[$0] }), run.runKind == "conductor" else { return sum }
            return sum + max(event.payload.tokens ?? 0, 0)
        }
    }
}
