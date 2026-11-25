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
    /// "Dispatch on", "Paused · Deploy freeze", "Holding · Claude limit", "Symphony stopped", "Paused · Updating to
    /// v0.0.1.42".
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
    /// The paused usage-limit hold **Try Now** checks at once, nil when none is paused.
    public var tryNow: StateSnapshot.UsageLimit?
    /// The update under way (S3a, S3b): it takes the place of Pause and Resume Dispatch with the menu's update
    /// actions.
    public var update: UpdateHold?
    /// The version the word says dispatch is updating to: the update's under way, or the one an update's pause names.
    public var updatingTo: String?

    public static let listLimit = 5
    public static let pauseTitle = "Pause Dispatch…"
    public static let resumeTitle = Overview.resumeTitle
    public static let tryNowTitle = StatusMenu.tryNowTitle
    public static let startTitle = StatusMenu.startTitle
    public static let cancelUpdateTitle = UpdateMenu.cancelUpdateTitle
    public static let updateNowTitle = UpdateMenu.updateNowTitle

    /// An update Symphony has ready holds nothing (TP-1590), so Pause and Resume Dispatch stay beside it.
    public var canPause: Bool { offersPause && (mode == .on || mode == .holding) }
    /// Pause Dispatch shows, enabled when `canPause`, unless an update under way holds dispatch, as in the menu.
    public var offersPause: Bool { update?.isReady != false }
    public var canResume: Bool { update?.isReady != false && mode == .paused }
    /// Try Now sits beside the limits it checks; a stopped Symphony has none.
    public var canTryNow: Bool { mode != .stopped && tryNow != nil }
    /// Cancel Update, before and after the restart timeout; never while the release downloads or Symphony stops.
    public var canCancelUpdate: Bool { update?.canCancel == true }
    /// Update Now Anyway, once the agent runs outlast the restart timeout.
    public var canUpdateNow: Bool { canCancelUpdate && update?.offersUpdateNow == true }

    /// What the status line's control says (TP-1498): "Dispatch paused" while paused, the reason in its help; the
    /// word otherwise.
    public var lineWord: String { mode == .paused ? Self.pausedWord : word }
    public static let pausedWord = "Dispatch paused"

    /// The control's dot pulses while dispatch is on.
    public var live: Bool { mode == .on }

    /// "Dispatch on, 3 working", or "Dispatch paused, updating to v0.0.1.42" while an update holds dispatch.
    public var accessibilityLabel: String {
        if let updatingTo {
            switch mode {
            case .paused: return "Dispatch paused, updating to v\(updatingTo)"
            case .on: return "Dispatch on, updating to v\(updatingTo)"
            case .holding, .stopped: return word
            }
        }
        guard mode != .stopped else { return word }
        let count = working.count + moreWorking
        return "\(word), \(count) working"
    }

    /// `paused` is the menu's reading of Symphony's status, for a state payload that hasn't arrived yet. `update` is
    /// the update under way, nil when there is none.
    public init(
        window: WindowState,
        paused: Bool,
        state: OverviewState?,
        update: UpdateHold? = nil,
        now: Date,
        timeZone: TimeZone = .current
    ) {
        self.update = update
        guard window.servesPages else {
            mode = .stopped
            word = Self.stoppedWord(window)
            status = .idle
            canStart = window == .stopped && update == nil
            (working, queued, moreWorking, moreQueued, pauseFacts, limits) = ([], [], 0, 0, [], [])
            // Symphony stops for the update's swap.
            if let update {
                updatingTo = update.version
                word = update.title
            }
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
        tryNow = holds.first(where: \.canTryNow)
        if state?.snapshot.budget?.dailyPaused == true { limits.append("Daily token budget used up, resets at midnight UTC") }

        if let pause = state?.snapshot.pause ?? (paused ? StateSnapshot.Pause() : nil) {
            mode = .paused
            status = .you
            let reason = pause.reason?.trimmingWhitespace() ?? ""
            // The update's version is its `build` reason's field; a Symphony that predates reasons names none.
            let pausedBy = state?.snapshot.updatePauseVersion
            updatingTo = (update?.isReady == true ? nil : update?.version) ?? pausedBy
            if let updatingTo {
                word = "Paused · Updating to v\(updatingTo)"
            } else {
                word = reason.isEmpty ? "Paused" : "Paused · \(reason)"
            }
            let by = pausedBy.map { "an update to v\($0)" } ?? (reason == ControlAction.pauseReason ? "You, from the menu bar" : "You")
            pauseFacts = [TicketList.Fact(label: "By", value: by)]
            if let since = pause.since {
                pauseFacts.append(TicketList.Fact(label: "Since", value: StatusMenu.clockTime(since, now: reference, timeZone: timeZone, dateFormat: "MMM d, HH:mm")))
            }
            pauseFacts.append(TicketList.Fact(label: "Why", value: reason.isEmpty ? "No reason given" : reason))
        } else if let hold = holds.first {
            mode = .holding
            status = .idle
            word = "Holding · " + (hold.isAPIUnreachable ? StatusMenu.apiUnreachableName(hold) : Self.limitsWord(holds))
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
        // The release downloads, or the update pauses dispatch: it isn't paused yet. One Symphony has ready
        // pauses nothing: dispatch reads as on, and the update names its version (TP-1590).
        if mode != .paused, let update {
            updatingTo = update.isReady ? nil : update.version
            word = update.isReady ? "\(word) · \(update.title)" : update.title
        }
    }

    /// "Claude limit", or every provider held at its usage limit when more than one is: "Claude and OpenCode Go limits".
    static func limitsWord(_ holds: [StateSnapshot.UsageLimit]) -> String {
        var names: [String] = []
        for hold in holds where !hold.isAPIUnreachable {
            let name = StatusMenu.providerName(hold.provider)
            if !names.contains(name) { names.append(name) }
        }
        guard let last = names.last else { return "limit" }
        guard names.count > 1 else { return "\(last) limit" }
        return names.dropLast().joined(separator: ", ") + " and " + last + " limits"
    }

    private static func stoppedWord(_ window: WindowState) -> String {
        switch window {
        case .starting: "Symphony starting"
        case .notAnswering: "Symphony not answering"
        case .firstLaunch: "Symphony not set up"
        case .stopped, .connected, .lagging: "Symphony stopped"
        }
    }

    private static func line(_ row: TicketList.Row) -> String {
        row.title.map { "\(row.identifier) · \($0)" } ?? row.identifier
    }
}

/// D12a: the Pause Dispatch sheet (P5). Nothing pauses until its button is pressed.
public enum PauseSheet {
    public static let title = "Pause dispatch?"
    public static let happens = "No new run starts in any repo until you resume."
    public static let stays = "Runs working now go on to their end. Nothing moves in Linear, and Resume Dispatch starts dispatch again."
    public static let reasonLabel = "Reason (optional)"
    public static let reasonPrompt = "Deploy freeze"
    public static let reasonHelp = "Shown wherever the pause shows: the toolbar, Home and the menu."
    public static let buttonTitle = "Pause Dispatch"

    /// The request the sheet sends: the reason typed, or the app's own when none was.
    public static func action(reason: String) -> ControlAction {
        .pauseWithReason(reason.trimmingWhitespace())
    }
}
