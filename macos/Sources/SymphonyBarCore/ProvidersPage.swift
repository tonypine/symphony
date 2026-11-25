import Foundation

/// Factory › Providers (TP-1534), as the catalog draws it (`providersPage` in `docs/design/catalog/stories.js`): the
/// providers in use, then those not in use, each a List card with its name, one fact and its state in a line; beside
/// them the picked provider's page: its state as a Situation line, Pause or Resume, its usage windows as one-line
/// meters and its facts. A block is drawn only when it has content. Everything is read from the state's `providers`
/// (TP-1533), so a Pause or a Resume shows as soon as Symphony's next state says so. A provider set up with an API key
/// (TP-1540, `ProviderKeys`) also has a Key block: its key, Test connection, and Enable or Disable; its state reads Off
/// while it isn't enabled, and its facts say whether its key is set. The keys are the app's, not Symphony's. A provider
/// whose usage Symphony reads (TP-1535, `ProviderReserve`) has "Stop new runs at" under its meters, saved to
/// `symphony.yml`, and each meter draws its stop mark at that reserve; once a window reaches it the provider reads
/// "At your reserve".
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

    /// A usage window as a one-line meter: its name, the share used, where new runs stop (the provider's reserve) and
    /// when it resets.
    public struct Meter: Equatable, Identifiable {
        public let id: String
        public let label: String
        public let percent: Int
        public var stop: Int? = nil
        public let resets: String?
    }

    /// "Stop new runs at": the provider's reserve as a whole percent (nil for none), the shares offered, and whether a
    /// save is on its way.
    public struct ReserveControl: Equatable {
        public let percent: Int?
        public let choices: [Int]
        public let saving: Bool

        /// The pop-up's word for `percent`: "90 %", or "No reserve".
        public static func title(_ percent: Int?) -> String { percent.map { "\($0) %" } ?? ProviderReserve.noneTitle }

        /// What the pop-up shows.
        public var title: String { Self.title(percent) }
    }

    /// A fact of the Access block.
    public struct Fact: Equatable, Identifiable {
        public let label: String
        public let value: String

        public var id: String { label }
    }

    /// The Key block of a provider set up with an API key: the key field, Test connection, the test's result, and
    /// Enable (once a test passed) or Disable (while it is on), and Remove Key while one is stored.
    public struct KeyBlock: Equatable {
        public let variable: String
        /// What the field holds: the key typed, else the key stored.
        public let text: String
        public let stored: Bool
        public let enabled: Bool
        public let testing: Bool
        public let canTest: Bool
        public let canEnable: Bool
        public let result: ProviderKeyCheck.Result?

        /// The switch the block offers: Disable while on, Enable once a test passed, else none.
        public var toggle: Bool? { enabled ? false : canEnable ? true : nil }
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
        /// Its Key block; none for a provider that takes no key, or while the keys aren't read yet.
        public var key: KeyBlock? = nil
        /// "Stop new runs at"; none for a provider whose usage Symphony can't read.
        public var reserve: ReserveControl? = nil

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
    public static let keyTitle = "Key"
    public static let testTitle = "Test connection"
    public static let enableTitle = "Enable"
    public static let disableTitle = "Disable"
    public static let removeKeyTitle = "Remove Key"
    public static let reserveTitle = "Stop new runs at"
    public static let reserveRefusedTitle = "Could not save the reserve"
    public static let atReserveWord = "At your reserve"
    public static let keySet = "set"
    public static let keyNotSet = "not set"

    /// The providers as the state lists them; nil when Symphony predates the list.
    public let providers: [StateSnapshot.Provider]?
    /// Symphony's clock, so ages and times read as on every other page.
    public let now: Date
    public let timeZone: TimeZone
    /// The provider keys and which providers are enabled, from the app's secrets; nil until they are read.
    public let keys: ProviderKeys?
    /// The Key blocks' keys typed, tests and results.
    public let keyEditor: ProviderKeyEditor
    /// The reserves saved to `symphony.yml` since Symphony last said, by provider id (nil for none), so a save shows at
    /// once; Symphony's own word replaces each once it reads the file again.
    public let savedReserves: [String: Int?]
    /// The provider whose reserve is being saved.
    public let savingReserve: String?

    public init(
        providers: [StateSnapshot.Provider]?, now: Date = Date(), timeZone: TimeZone = .current, keys: ProviderKeys? = nil,
        keyEditor: ProviderKeyEditor = ProviderKeyEditor(), savedReserves: [String: Int?] = [:], savingReserve: String? = nil
    ) {
        self.providers = providers
        self.now = now
        self.timeZone = timeZone
        self.keys = keys
        self.keyEditor = keyEditor
        self.savedReserves = savedReserves
        self.savingReserve = savingReserve
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
            id: provider.id, name: provider.name, state: state(provider), move: move, usage: meters(provider), facts: facts(provider),
            key: keyBlock(provider.id), reserve: reserveControl(provider)
        )
    }

    /// The reserve of `provider` as a whole percent: one saved since Symphony last said, else Symphony's; nil for none.
    public func reservePercent(_ provider: StateSnapshot.Provider) -> Int? {
        if let saved = savedReserves[provider.id] { return saved }
        return provider.reserve.map(ProviderReserve.percent)
    }

    /// `saved` without each reserve the state's `providers` now say the same of.
    public static func settledReserves(_ saved: [String: Int?], providers: [StateSnapshot.Provider]?) -> [String: Int?] {
        saved.filter { id, percent in
            guard let provider = providers?.first(where: { $0.id == id }) else { return true }
            return provider.reserve.map(ProviderReserve.percent) != percent
        }
    }

    /// "Stop new runs at" for a provider whose usage Symphony reads, offering the current share too when it isn't one
    /// of the usual ones.
    func reserveControl(_ provider: StateSnapshot.Provider) -> ReserveControl? {
        guard ProviderReserve.takesReserve(provider.id) else { return nil }
        let percent = reservePercent(provider)
        let choices = Set(ProviderReserve.choices + [percent].compactMap { $0 }).sorted()
        return ReserveControl(percent: percent, choices: choices, saving: savingReserve == provider.id)
    }

    /// The Key block of the provider `id`, nil for one that takes no key or while the keys aren't read.
    func keyBlock(_ id: String) -> KeyBlock? {
        guard let keys, let spec = ProviderKeys.spec(id) else { return nil }
        return KeyBlock(
            variable: spec.variable, text: keyEditor.text(id, keys: keys), stored: keys.hasKey(id), enabled: keys.isEnabled(id),
            testing: keyEditor.testing == id, canTest: keyEditor.canTest(id, keys: keys), canEnable: keyEditor.canEnable(id, keys: keys),
            result: keyEditor.result(id, keys: keys)
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

    /// Where `provider` stands. The Director's pause reads first, then a hold Symphony keeps on it (its reserve, then a
    /// usage limit), then Off for a provider set up with a key that isn't enabled, then Not in use (Available for such
    /// a provider once it is enabled). A hold wins over the app's own key store and over Not in use, so the page says
    /// what the status menu says: Symphony reads the provider's usage with its own key, which the app may not hold.
    public func state(_ provider: StateSnapshot.Provider) -> State {
        if provider.paused {
            let age = provider.pausedSince.map { Overview.duration(Int(now.timeIntervalSince($0))) }
            return State(
                status: .you, word: "Paused", cause: age.map { "You paused it \($0) ago." } ?? "You paused it.",
                waits: provider.inUse ? Self.waits : nil, short: age.map { "Paused by you · \($0)" } ?? "Paused by you", live: false
            )
        }
        if provider.atReserve {
            let until = provider.heldUntil
            return State(
                status: .you, word: Self.atReserveWord, cause: reserveCause(provider),
                waits: Self.waits + (until.map { " Resumes \(longTime($0))." } ?? ""),
                short: Self.atReserveWord + (until.map { " · until \(shortTime($0))" } ?? ""), live: false
            )
        }
        if provider.held {
            let until = provider.heldUntil
            return State(
                status: .problem, word: "Limit reached", cause: "Its usage limit is reached.",
                waits: Self.waits + (until.map { " Resumes \(longTime($0))." } ?? ""),
                short: "Limit reached" + (until.map { " · until \(shortTime($0))" } ?? ""), live: false
            )
        }
        let keyed = keys != nil && ProviderKeys.spec(provider.id) != nil
        if keyed, let keys, !keys.isEnabled(provider.id) {
            let cause = keys.hasKey(provider.id) ? "You turned it off." : "It has no key."
            return State(status: .idle, word: Self.offWord, cause: cause, waits: nil, short: Self.offWord, live: false)
        }
        if !provider.inUse {
            let word = keyed ? "Available" : "Not in use"
            return State(status: keyed ? .done : .idle, word: word, cause: "No kind of run is set to it.", waits: nil, short: word, live: false)
        }
        let working = provider.working
        return State(
            status: .done, word: "Available",
            cause: working > 0 ? "\(working) \(working == 1 ? "run is" : "runs are") working on it." : "No run is on it now.",
            waits: nil, short: working > 0 ? "\(working) working" : "Available", live: working > 0
        )
    }

    public static let offWord = "Off"

    /// "The week is at 90 %, where you stop new runs.": the fullest window at or past the reserve.
    func reserveCause(_ provider: StateSnapshot.Provider) -> String {
        let reserve = reservePercent(provider)
        let reached = provider.usageWindows
            .compactMap { window in window.utilization.map { (window.name, Self.percent($0)) } }
            .filter { window in reserve.map { window.1 >= $0 } ?? true }
            .max { $0.1 < $1.1 }
        guard let reached else { return "It is at your reserve, where you stop new runs." }
        return "\(Self.windowSubject(reached.0)) is at \(reached.1) %, where you stop new runs."
    }

    /// A window as the subject of a sentence: "The week", "The 5 hours".
    static func windowSubject(_ name: String) -> String {
        switch name {
        case weekWindow: "The week"
        case "five_hour": "The 5 hours"
        case "seven_day_opus": "The Opus week"
        case "seven_day_sonnet": "The Sonnet week"
        default: "The " + windowLabel(name).lowercased()
        }
    }

    /// A key test's result as a Situation line: Works in green, Failed in red.
    public static func state(_ result: ProviderKeyCheck.Result) -> State {
        State(status: result.passed ? .done : .problem, word: result.word, cause: result.detail, waits: nil, short: result.word, live: false)
    }

    /// What a pause or a limit means for the runs.
    static let waits = "New runs start on their fallbacks, or wait."

    // MARK: Usage and facts

    static let weekWindow = "seven_day"

    /// OpenCode Go's monthly limit (TP-1642).
    static let monthWindow = "monthly"

    /// Each usage window Symphony read a share for, as a one-line meter with its stop mark at the reserve, shortest
    /// window first: 5 hours, the weeks, the month, then any other.
    func meters(_ provider: StateSnapshot.Provider) -> [Meter] {
        let stop = reservePercent(provider)
        let windows = provider.usageWindows.enumerated()
            .sorted { ($0.element.name.windowRank, $0.offset) < ($1.element.name.windowRank, $1.offset) }
            .map(\.element)
        return windows.compactMap { window in
            guard let used = window.utilization else { return nil }
            return Meter(
                id: window.name, label: Self.windowLabel(window.name), percent: Self.percent(used), stop: stop,
                resets: window.resetsAt.map(longTime)
            )
        }
    }

    /// Its key, set or not set, for a provider set up with one; harnesses, the kinds of run set to it, the kinds it
    /// backs up, the runs working on it and its tokens today; a fact with nothing to say is left out.
    func facts(_ provider: StateSnapshot.Provider) -> [Fact] {
        let working = provider.working
        let key = keys.flatMap { keys in
            ProviderKeys.spec(provider.id).map { "\($0.variable) · \(keys.hasKey(provider.id) ? Self.keySet : Self.keyNotSet)" }
        }
        let facts: [(String, String)] = [
            (Self.keyTitle, key ?? ""),
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
        case monthWindow: return "Month"
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

private extension String {
    /// A usage window's place by its length: the 5 hours, the week, its model weeks (Opus), the month (OpenCode Go's, TP-1642), then any other.
    var windowRank: Int {
        if self == "five_hour" { return 0 }
        if self == ProvidersPage.weekWindow { return 1 }
        if hasPrefix(ProvidersPage.weekWindow) { return 2 }
        if self == ProvidersPage.monthWindow { return 3 }
        return 4
    }
}
