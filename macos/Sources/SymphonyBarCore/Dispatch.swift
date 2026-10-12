import Foundation

/// C2: the toolbar's dispatch control and its popover (D12a), from the window's state and one state payload.
public struct DispatchControl: Equatable {
    public enum Mode: Equatable {
        /// New runs start as slots free up.
        case on
        /// The operator paused dispatch.
        case paused
        /// A provider's usage limit or the daily token budget holds new runs.
        case holding
        /// Symphony doesn't answer: stopped, starting, not answering or not set up.
        case stopped
    }

    public var mode: Mode
    /// "Dispatch on", "Paused · Deploy freeze", "Holding · Claude limit", "Symphony stopped".
    public var word: String
    /// The dot's colour: orange while paused.
    public var status: DesignTokens.Status
    /// Only a stopped Symphony offers **Start Symphony**; starting or not answering has nothing to press.
    public var canStart: Bool
    /// "SHOP-301 · Checkout total", the runs working now, at most `listLimit`.
    public var working: [String]
    /// The tickets next in line, at most `listLimit`.
    public var queued: [String]
    /// How many working and queued tickets the lists leave out.
    public var moreWorking: Int
    public var moreQueued: Int
    /// While paused: who paused, when and why.
    public var pauseFacts: [TicketList.Fact]
    /// While a limit holds: which one and when it resets, one line each.
    public var limits: [String]

    public static let listLimit = 5
    public static let pauseTitle = "Pause Dispatch…"
    public static let resumeTitle = Overview.resumeTitle
    public static let forceTitle = "Force a Ticket…"
    public static let startTitle = StatusMenu.startTitle

    public var canPause: Bool { mode == .on || mode == .holding }
    public var canResume: Bool { mode == .paused }
    public var canForce: Bool { mode != .stopped }

    /// "Dispatch on, 3 working".
    public var accessibilityLabel: String {
        guard mode != .stopped else { return word }
        let count = working.count + moreWorking
        return "\(word), \(count) working"
    }

    /// `paused` is the menu's reading of Symphony's status, for a state payload that hasn't arrived yet.
    public init(window: WindowState, paused: Bool, state: OverviewState?, now: Date, timeZone: TimeZone = .current) {
        guard window == .connected else {
            mode = .stopped
            word = Self.stoppedWord(window)
            status = .idle
            canStart = window == .stopped
            (working, queued, moreWorking, moreQueued, pauseFacts, limits) = ([], [], 0, 0, [], [])
            return
        }
        canStart = false
        let reference = state?.generatedAt ?? now
        let list = state.map { TicketList(state: $0, now: now, timeZone: timeZone) }
        let working = list?.rows.filter { $0.stage == .working } ?? []
        let queued = list?.rows.filter { $0.stage == .queued } ?? []
        self.working = working.prefix(Self.listLimit).map(Self.line)
        self.queued = queued.prefix(Self.listLimit).map(Self.line)
        moreWorking = max(working.count - Self.listLimit, 0)
        moreQueued = max(queued.count - Self.listLimit, 0)

        let holds = (state?.snapshot.usageLimits ?? []).filter { $0.phase != .canary }
        limits = holds.map { StatusMenu.usageLimitLine($0, now: reference, timeZone: timeZone) }
        if state?.snapshot.budget?.dailyPaused == true { limits.append("Daily token budget used up, resets at midnight UTC") }

        if let pause = state?.snapshot.pause ?? (paused ? StateSnapshot.Pause() : nil) {
            mode = .paused
            status = .you
            let reason = pause.reason?.trimmingWhitespace() ?? ""
            word = reason.isEmpty ? "Paused" : "Paused · \(reason)"
            pauseFacts = [TicketList.Fact(label: "By", value: reason == ControlAction.pauseReason ? "You, from the menu bar" : "You")]
            if let since = pause.since {
                pauseFacts.append(TicketList.Fact(label: "Since", value: StatusMenu.clockTime(since, now: reference, timeZone: timeZone, dateFormat: "MMM d, HH:mm")))
            }
            pauseFacts.append(TicketList.Fact(label: "Why", value: reason.isEmpty ? "No reason given" : reason))
        } else if let hold = holds.first {
            mode = .holding
            status = .idle
            word = "Holding · " + (hold.isAPIUnreachable ? StatusMenu.apiUnreachableName(hold) : "\(StatusMenu.providerName(hold.provider)) limit")
            pauseFacts = []
        } else if state?.snapshot.budget?.dailyPaused == true {
            mode = .holding
            status = .idle
            word = "Holding · token budget"
            pauseFacts = []
        } else {
            mode = .on
            status = .done
            word = "Dispatch on"
            pauseFacts = []
        }
    }

    private static func stoppedWord(_ window: WindowState) -> String {
        switch window {
        case .starting: "Symphony starting"
        case .notAnswering: "Symphony not answering"
        case .firstLaunch: "Symphony not set up"
        case .stopped, .connected: "Symphony stopped"
        }
    }

    private static func line(_ row: TicketList.Row) -> String {
        row.title.map { "\(row.identifier) · \($0)" } ?? row.identifier
    }
}

/// D12a: the Pause Dispatch sheet (P5). Nothing pauses until its button is pressed.
public enum PauseSheet {
    public static let title = "Pause dispatch?"
    public static let happens = "No new run starts in any repo, forced tickets included, until you resume."
    public static let stays = "Runs working now go on to their end. Nothing moves in Linear, and Resume Dispatch starts dispatch again."
    public static let reasonLabel = "Reason (optional)"
    public static let reasonPrompt = "Deploy freeze"
    public static let reasonHelp = "Shown wherever the pause shows: the toolbar, the Overview and the menu."
    public static let buttonTitle = "Pause Dispatch"

    /// The request the sheet sends: the reason typed, or the app's own when none was.
    public static func action(reason: String) -> ControlAction {
        .pauseWithReason(reason.trimmingWhitespace())
    }
}

/// D12b: the Force a Ticket sheet (P5). It finds the ticket among those Symphony tracks as its identifier is typed,
/// and shows its title and state before anything is sent.
public enum ForceSheet {
    public static let title = "Force a ticket?"
    public static let fieldLabel = "Ticket"
    public static let fieldPrompt = "TP-123"
    public static let skips = "Forcing skips the queue and the slot limits: the ticket runs on the forced allowance."
    public static let keeps = "It still waits for its blockers, its reviews, a pause and the per-ticket token cap. Forcing never moves a ticket or approves a review."
    public static let buttonTitle = "Force"
    public static let suggestionLimit = 5

    /// What the field holds, as the identifier to send; nil while it is empty.
    public static func identifier(_ input: String) -> String? {
        StatusMenu.forceIdentifier(input).map { $0.uppercased() }
    }

    /// The tracked tickets whose identifier starts with what was typed, the exact one first.
    public static func matches(_ input: String, in list: TicketList?) -> [TicketList.Row] {
        guard let identifier = identifier(input), let list else { return [] }
        let found = list.rows.filter { $0.identifier.uppercased().hasPrefix(identifier) }
        let exact = found.filter { $0.identifier.uppercased() == identifier }
        return Array((exact + found.filter { $0.identifier.uppercased() != identifier }).prefix(suggestionLimit))
    }

    /// The tracked ticket the field names exactly, nil while it names none.
    public static func ticket(_ input: String, in list: TicketList?) -> TicketList.Row? {
        guard let identifier = identifier(input) else { return nil }
        return list?.row(identifier)
    }

    /// The line under the field: the ticket's title and state, or why there is none.
    public static func summary(_ input: String, in list: TicketList?) -> String? {
        guard let identifier = identifier(input) else { return nil }
        guard let row = ticket(input, in: list) else {
            return "Symphony doesn't track \(identifier) yet. It looks it up in Linear when you force it."
        }
        let state = row.state.map { "\($0) · " } ?? ""
        return [row.title, "\(state)\(row.stage.title)\(row.forced ? " · already forced" : "")"].compactMap { $0 }.joined(separator: "\n")
    }

    /// Force is on once the field names a ticket that isn't forced already.
    public static func canForce(_ input: String, in list: TicketList?) -> Bool {
        guard identifier(input) != nil else { return false }
        return ticket(input, in: list)?.forced != true
    }
}
