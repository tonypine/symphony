import Foundation

/// Factory › Providers (TP-1534), as the catalog draws it (`providersPage` in `docs/design/catalog/stories.js`): the
/// providers in use, then those not in use, each a List card with its name, one fact and its state in a line; beside
/// them the picked provider's page: its state as a Situation line, Pause or Resume, its usage windows as one-line
/// meters and its facts. A block is drawn only when it has content. Everything is read from the state's `providers`
/// (TP-1533), so a Pause or a Resume shows as soon as Symphony's next state says so.
public struct ProvidersPage: Equatable {
    /// The move the page's button makes.
    public enum Move: Equatable {
        case pause, resume

        public var title: String {
            switch self {
            case .pause: ProvidersPage.pauseTitle
            case .resume: ProvidersPage.resumeTitle
            }
        }

        /// The SF Symbol before the title.
        public var glyph: String {
            switch self {
            case .pause: "pause.fill"
            case .resume: "play.fill"
            }
        }
    }

    /// Where a provider stands: the Situation line's status, word, cause and what waits on it, and the List card's
    /// short line.
    public struct State: Equatable {
        public let status: DesignTokens.Status
        public let word: String
        public let cause: String
        public let waits: String?
        public let short: String
        /// Runs are working on it: the card's dot is live.
        public let live: Bool

        /// What VoiceOver reads: "Paused. You paused it 12 min ago. New runs start on their fallbacks or wait."
        public var spoken: String { [word + ".", cause, waits].compactMap { $0 }.joined(separator: " ") }
    }

    /// One List card: the provider's name, its one fact and its state.
    public struct Card: Equatable, Identifiable {
        public let id: String
        public let title: String
        public let fact: String?
        public let status: DesignTokens.Status
        public let statusLine: String
        public let live: Bool
    }

    /// A group of the list: In use, or Not in use.
    public struct Section: Equatable, Identifiable {
        public let title: String
        public let cards: [Card]

        public var id: String { title }
    }

    /// A usage window as a one-line meter: its name, the share used and when it resets.
    public struct Meter: Equatable, Identifiable {
        public let id: String
        public let label: String
        public let percent: Int
        public let resets: String?
    }

    /// A fact of the Access block.
    public struct Fact: Equatable, Identifiable {
        public let label: String
        public let value: String

        public var id: String { label }
    }

    /// The picked provider's page.
    public struct Detail: Equatable {
        public let id: String
        public let name: String
        public let state: State
        /// Pause or Resume; none for a provider not in use and not paused.
        public let move: Move?
        /// Its usage windows; empty when Symphony can read none, and then the page has no Usage block.
        public let usage: [Meter]
        /// Its facts, each only when known.
        public let facts: [Fact]

        /// The control the button sends.
        public var action: ControlAction? { move.map { ProvidersPage.action($0, provider: id, name: name) } }
    }

    public static let inUseTitle = "In use"
    public static let notInUseTitle = "Not in use"
    public static let usageTitle = "Usage"
    public static let accessTitle = "Access"
    public static let pauseTitle = "Pause"
    public static let resumeTitle = "Resume"
    public static let emptyTitle = "Symphony lists no provider."

    /// The providers as the state lists them; nil when Symphony predates the list.
    public let providers: [StateSnapshot.Provider]?
    /// Symphony's clock, so ages and times read as on every other page.
    public let now: Date
    public let timeZone: TimeZone

    public init(providers: [StateSnapshot.Provider]?, now: Date = Date(), timeZone: TimeZone = .current) {
        self.providers = providers
        self.now = now
        self.timeZone = timeZone
    }

    /// The providers in the list's order: in use first, then not in use, each in Symphony's order.
    public var ordered: [StateSnapshot.Provider] {
        let all = providers ?? []
        return all.filter(\.inUse) + all.filter { !$0.inUse }
    }

    /// In use, then Not in use; a group with no provider isn't drawn.
    public var sections: [Section] {
        let all = providers ?? []
        return [(Self.inUseTitle, all.filter(\.inUse)), (Self.notInUseTitle, all.filter { !$0.inUse })]
            .filter { !$0.1.isEmpty }
            .map { Section(title: $0.0, cards: $0.1.map(card)) }
    }

    /// The provider `selection` names, else the first of the list; nil when there is none.
    public func selected(_ selection: String?) -> StateSnapshot.Provider? {
        let ordered = ordered
        return ordered.first { $0.id == selection } ?? ordered.first
    }

    /// The id of the provider `step` places from `selection` in the list's order (the arrow keys), staying at the ends.
    public func id(after selection: String?, step: Int) -> String? {
        let ids = ordered.map(\.id)
        guard let current = selected(selection).flatMap({ ids.firstIndex(of: $0.id) }) else { return nil }
        return ids[min(max(current + step, 0), ids.count - 1)]
    }

    /// The page of the provider `selection` names, else of the first.
    public func detail(_ selection: String?) -> Detail? {
        guard let provider = selected(selection) else { return nil }
        let move: Move? = provider.paused ? .resume : provider.inUse ? .pause : nil
        return Detail(
            id: provider.id, name: provider.name, state: state(provider), move: move, usage: meters(provider), facts: facts(provider)
        )
    }

    /// The control for `move` on the provider `id`, named `name` for a person.
    public static func action(_ move: Move, provider id: String, name: String) -> ControlAction {
        switch move {
        case .pause: .pauseProvider(id, name: name)
        case .resume: .resumeProvider(id, name: name)
        }
    }

    // MARK: The card

    func card(_ provider: StateSnapshot.Provider) -> Card {
        let state = state(provider)
        return Card(
            id: provider.id, title: provider.name, fact: fact(provider), status: state.status, statusLine: state.short, live: state.live
        )
    }

    /// The card's one fact: the share of the week used when Symphony reads it, else the tokens today, else none.
    func fact(_ provider: StateSnapshot.Provider) -> String? {
        if let week = provider.usageWindows.first(where: { $0.name == Self.weekWindow }), let used = week.utilization {
            return "\(Self.percent(used)) % of the week"
        }
        guard provider.tokensToday > 0 else { return nil }
        return "\(ProgressMeterReading.amount(Double(provider.tokensToday), unit: .tokens)) today"
    }

    // MARK: The state

    /// Where `provider` stands. Not in use reads first, unless the Director paused it; the Director's pause before a
    /// usage limit's hold.
    public func state(_ provider: StateSnapshot.Provider) -> State {
        if provider.paused {
            let age = provider.pausedSince.map { Overview.duration(Int(now.timeIntervalSince($0))) }
            return State(
                status: .you, word: "Paused", cause: age.map { "You paused it \($0) ago." } ?? "You paused it.",
                waits: provider.inUse ? Self.waits : nil, short: age.map { "Paused by you · \($0)" } ?? "Paused by you", live: false
            )
        }
        if !provider.inUse {
            return State(status: .idle, word: "Not in use", cause: "No kind of run is set to it.", waits: nil, short: "Not in use", live: false)
        }
        if provider.held {
            let until = provider.heldUntil
            return State(
                status: .problem, word: "Limit reached", cause: "Its usage limit is reached.",
                waits: Self.waits + (until.map { " Resumes \(longTime($0))." } ?? ""),
                short: "Limit reached" + (until.map { " · until \(shortTime($0))" } ?? ""), live: false
            )
        }
        let working = provider.working
        return State(
            status: .done, word: "Available",
            cause: working > 0 ? "\(working) \(working == 1 ? "run is" : "runs are") working on it." : "No run is on it now.",
            waits: nil, short: working > 0 ? "\(working) working" : "Available", live: working > 0
        )
    }

    /// What a pause or a limit means for the runs.
    static let waits = "New runs start on their fallbacks, or wait."

    // MARK: Usage and facts

    static let weekWindow = "seven_day"

    /// Each usage window Symphony read a share for, as a one-line meter.
    func meters(_ provider: StateSnapshot.Provider) -> [Meter] {
        provider.usageWindows.compactMap { window in
            guard let used = window.utilization else { return nil }
            return Meter(id: window.name, label: Self.windowLabel(window.name), percent: Self.percent(used), resets: window.resetsAt.map(longTime))
        }
    }

    /// Harnesses, the kinds of run set to it, the kinds it backs up, the runs working on it and its tokens today; a
    /// fact with nothing to say is left out.
    func facts(_ provider: StateSnapshot.Provider) -> [Fact] {
        let working = provider.working
        let facts: [(String, String)] = [
            ("Harnesses", provider.harnesses.map { Harness(rawValue: $0)?.title ?? $0 }.joined(separator: ", ")),
            ("Runs set to it", Self.kinds(provider.kinds)),
            ("Fallback for", Self.kinds(provider.fallbackFor)),
            ("Working now", working > 0 ? "\(working) \(working == 1 ? "run" : "runs")" : ""),
            ("Tokens today", provider.tokensToday > 0 ? ProgressMeterReading.amount(Double(provider.tokensToday), unit: .tokens) : ""),
        ]
        return facts.filter { !$0.1.isEmpty }.map { Fact(label: $0.0, value: $0.1) }
    }

    /// Kinds of run by the names the Runs page gives them: "Implementation, Code Review".
    static func kinds(_ ids: [String]) -> String {
        ids.map { id in RunKind(rawValue: id).map { RunsPage.title($0) } ?? id }.joined(separator: ", ")
    }

    /// A window's name for a person: "5 hours", "Week".
    public static func windowLabel(_ name: String) -> String {
        switch name {
        case "five_hour": return "5 hours"
        case weekWindow: return "Week"
        case "seven_day_opus": return "Week, Opus"
        case "seven_day_sonnet": return "Week, Sonnet"
        default:
            let words = name.replacingOccurrences(of: "_", with: " ")
            return words.prefix(1).uppercased() + words.dropFirst()
        }
    }

    /// A share from 0 to 1 as a whole percent from 0 to 100.
    static func percent(_ used: Double) -> Int { ProgressMeterReading.clamped(Int((used * 100).rounded())) }

    // MARK: Times

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    /// "today 16:20", or "Thu 19 Nov, 14:00".
    func longTime(_ date: Date) -> String {
        let calendar = calendar
        if calendar.isDate(date, inSameDayAs: now) { return "today " + SharedDateFormatter.string(date, format: "HH:mm", calendar: calendar) }
        return SharedDateFormatter.string(date, format: "EEE d MMM, HH:mm", calendar: calendar)
    }

    /// "16:20" today, else "Thu 14:00".
    func shortTime(_ date: Date) -> String {
        let calendar = calendar
        return SharedDateFormatter.string(date, format: calendar.isDate(date, inSameDayAs: now) ? "HH:mm" : "EEE HH:mm", calendar: calendar)
    }
}
