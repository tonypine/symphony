import Foundation

// The ticket read's `lifecycle` and `phase_path` (`docs/control-api.md` § `lifecycle`, § `phase_path`) and what the
// Lifecycle section and the Phase path component say from them (`docs/design/director-ticket-page.md` §1 facts 7, 19
// and 20). Symphony computes both from the ticket's ledger; the app only says them, with the names as served.

/// Where the ticket is on its way to landing: the five stages in order and its tokens against its cap.
public struct TicketLifecycle: Equatable, Decodable {
    public enum StageState: String, Equatable, Decodable {
        case current, passed, skipped
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

        public init(id: String, name: String, state: StageState, visits: Int = 0, timeMs: Int = 0, agentTimeMs: Int = 0, tokens: Int = 0) {
            self.id = id
            self.name = name
            self.state = state
            self.visits = visits
            self.timeMs = timeMs
            self.agentTimeMs = agentTimeMs
            self.tokens = tokens
        }

        private enum CodingKeys: String, CodingKey {
            case id, name, state, visits, tokens
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
        /// "Code Review ×3": the stage's name, with its visits when it was entered more than once.
        public var title: String
        public var state: TicketLifecycle.StageState
        /// "Passed", "Now", "Skipped", "Not yet".
        public var word: String
        /// "Now · in Rework · 16 min so far": the word, the phase it is in when that isn't the stage's own name, and
        /// its time.
        public var line: String
        public var status: DesignTokens.Status
        public var accessibilityLabel: String
    }

    public struct Segment: Equatable, Identifiable {
        public var id: String
        public var name: String
        public var tokens: Int
        /// "2.4M".
        public var value: String
        public var series: DesignTokens.ChartSeries
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
        /// What the cap means now, in words; nil without a cap.
        public var note: String?
        public var accessibilityLabel: String

        /// The share of the bar's width each segment takes, then what is left: the cap, or the total past it.
        public var scale: Int { max(total, cap ?? 0) }
    }

    /// "In Code Review, visit 3", "Done", "Not started yet".
    public var whereLine: String
    /// "1 h 4 min of agent work", "No run yet".
    public var summary: String
    /// True while a stage is current: its dot works.
    public var live: Bool
    public var stages: [Stage]
    public var tokens: TokenBar

    /// The phases In Progress serves under its own stage name: no "in In Progress" on Coding.
    static let ownPhases: [String: String] = ["coding": "In Progress"]

    /// The section from `lifecycle`, with `phase` (`phase_path.current`) naming the phase a current stage is in when
    /// it is another than the stage's own: a ticket in Rework reads Code Review as current, "in Rework".
    public static func build(_ lifecycle: TicketLifecycle, phase: String? = nil) -> LifecycleModel {
        let stages = lifecycle.stages.map { stage(of: $0, phase: phase) }
        let current = lifecycle.stages.first { $0.id == lifecycle.current }
        let whereLine: String
        if let current {
            whereLine = "In \(current.name)" + (current.visits > 1 ? ", visit \(current.visits)" : "")
        } else if lifecycle.stages.last.map({ $0.id == "done" && $0.state == .passed }) == true {
            whereLine = "Done"
        } else if lifecycle.stages.contains(where: { $0.visits > 0 }) {
            whereLine = phase.map { "In \($0), outside the stages" } ?? "Outside the stages"
        } else {
            whereLine = "Not started yet"
        }
        let agentSeconds = lifecycle.stages.reduce(0) { $0 + $1.agentTimeMs } / 1_000
        let summary = agentSeconds > 0 ? "\(Overview.duration(agentSeconds)) of agent work" : "No run yet"
        return LifecycleModel(
            whereLine: whereLine, summary: summary, live: current != nil, stages: stages,
            tokens: tokenBar(lifecycle)
        )
    }

    static func stage(of stage: TicketLifecycle.Stage, phase: String?) -> Stage {
        let title = stage.name + (stage.visits > 1 ? " ×\(stage.visits)" : "")
        let (word, status): (String, DesignTokens.Status) = switch stage.state {
        case .current: ("Now", .working)
        case .passed: ("Passed", .done)
        case .skipped: ("Skipped", .idle)
        case .notYet: ("Not yet", .idle)
        }
        var parts = [word]
        if stage.state == .current, let phase, phase != stage.name, phase != ownPhases[stage.id] {
            parts.append("in \(phase)")
        }
        let seconds = stage.timeMs / 1_000
        if stage.timeMs > 0 {
            parts.append(Overview.duration(seconds) + (stage.state == .current ? " so far" : ""))
        }
        var spoken = [stage.name]
        if stage.visits > 1 { spoken.append("entered \(stage.visits) times") }
        spoken.append(word.lowercased())
        if parts.count > 1, parts[1].hasPrefix("in ") { spoken.append(parts[1]) }
        if stage.timeMs > 0 { spoken.append(Overview.spokenDuration(seconds) + (stage.state == .current ? " so far" : "")) }
        return Stage(
            id: stage.id, title: title, state: stage.state, word: word, line: parts.joined(separator: " · "), status: status,
            accessibilityLabel: spoken.joined(separator: ", ")
        )
    }

    static let series: [String: DesignTokens.ChartSeries] = ["coding": .series1, "code_review": .series2, "qa": .series3, "merging": .series4]

    static func tokenBar(_ lifecycle: TicketLifecycle) -> TokenBar {
        // Done takes no tokens: the four working stages fill the bar, in their landing order.
        let segments = lifecycle.stages.compactMap { stage -> Segment? in
            guard let series = series[stage.id] else { return nil }
            return Segment(id: stage.id, name: stage.name, tokens: stage.tokens, value: Overview.tokens(stage.tokens), series: series)
        }
        let total = lifecycle.tokens.total
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
        let level = Overview.level(fraction)
        let note: String? = percent.map { percent in
            if percent >= 100 { return "At the cap: no new run starts." }
            switch level {
            case .atLimit: return "Almost at the cap: the run finishes, the next one waits."
            case .near: return "Getting close: \(100 - percent) % left of the ticket's cap."
            case .normal: return "\(100 - percent) % of the ticket's cap left."
            }
        }
        let split = segments.filter { $0.tokens > 0 }.map { "\($0.name) \($0.value)" }
        let label = ["Tokens", value] + split + [note].compactMap { $0 }
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
