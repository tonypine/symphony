import Foundation

/// What Symphony is doing, as far as an automatic update cares.
public enum SymphonyActivity: Equatable {
    /// Symphony isn't running, so nothing can be interrupted.
    case notRunning
    /// Symphony answers with this many active agent runs, whether dispatch is paused or not.
    case running(activeRuns: Int)
    /// Symphony is starting, stopping, restarting or not answering, or an update is under way: wait.
    case busy

    /// `status` as the app's last poll saw it. `symphonyRunning` is whether the app's Symphony process runs, and
    /// `busy` whether the app is starting, stopping or restarting it, or updating.
    public init(status: SymphonyStatus, symphonyRunning: Bool, busy: Bool) {
        guard !busy else {
            self = .busy
            return
        }
        switch status {
        case let .running(snapshot, _), let .paused(snapshot, _):
            self = .running(activeRuns: snapshot.running)
        case .stopped:
            self = .notRunning
        case .starting:
            self = .busy
        case .error:
            // The app's Symphony runs but doesn't answer, so its runs are unknown; otherwise it exited.
            self = symphonyRunning ? .busy : .notRunning
        }
    }

    /// Idle means no active agent runs. Paused dispatch with runs still active is not idle.
    public var isIdle: Bool {
        switch self {
        case .notRunning:
            return true
        case let .running(activeRuns):
            return activeRuns == 0
        case .busy:
            return false
        }
    }
}

/// Decides when the app installs a newer release by itself, kept free of AppKit so it can be unit tested with an
/// injected clock. The app calls `tick` on each status poll and when the set time's timer fires, and `checked` after
/// each update check; it carries out the actions that come back.
///
/// - Automatically when idle installs an available release that isn't skipped as soon as Symphony has no active agent
///   runs. It never pauses dispatch to get there: while runs are active it waits for a later tick. After an install
///   that didn't happen it waits for the next check, unless it gave up because a run was active.
/// - Automatically at a set time checks for a release at the daily time and installs it, waiting for agent runs up to
///   the restart timeout. A time missed while the Mac slept or the app was closed waits for the next day.
/// - Manual never installs by itself.
///
/// Nothing installs while `UpdateEligibility.blocker` gives a reason.
public struct AutoUpdater: Equatable {
    /// How late a set-time attempt may still start, for a timer or poll that runs a little after the time. Later than
    /// that, as after a sleep, the time counts as missed.
    public static let lateness: TimeInterval = 10 * 60

    public enum Action: Equatable {
        /// Check for a newer release now: the set time has come. Its result goes to `checked`.
        case check
        /// Install `release` without asking. The drain waits up to `runsTimeout` for agent runs once dispatch is
        /// paused and then gives up; 0 gives up as soon as a run is active.
        case install(Release, runsTimeout: TimeInterval)
    }

    /// What the decisions read from the app each time.
    public struct Context: Equatable {
        public var mode: UpdateMode
        /// The daily time of Automatically at a set time.
        public var time: TimeOfDay
        /// The newer release the last check found, as available or skipped; nil when there is none.
        public var offer: UpdateOffer?
        /// Why updates are off, from `UpdateEligibility.blocker`; nil when they are allowed.
        public var blocker: String?
        public var activity: SymphonyActivity
        /// The restart timeout: how long a set-time install waits for agent runs.
        public var runsTimeout: TimeInterval

        public init(
            mode: UpdateMode,
            time: TimeOfDay,
            offer: UpdateOffer?,
            blocker: String?,
            activity: SymphonyActivity,
            runsTimeout: TimeInterval
        ) {
            self.mode = mode
            self.time = time
            self.offer = offer
            self.blocker = blocker
            self.activity = activity
            self.runsTimeout = runsTimeout
        }
    }

    /// When the next set-time attempt is due, nil unless Automatically at a set time is chosen. The app sets a timer
    /// for it.
    public private(set) var nextSetTime: Date?
    /// The time of day `nextSetTime` was worked out for, so a new time in Settings moves it.
    private var scheduledTime: TimeOfDay?
    /// True from the set time's check until its result.
    private var checkingAtSetTime = false
    /// True after an install started when idle, until the next check: an install that failed isn't retried on every
    /// poll.
    private var waitingForCheck = false

    public init() {}

    /// Called on each status poll and when the set time's timer fires.
    public mutating func tick(_ context: Context, now: Date, calendar: Calendar) -> Action? {
        guard context.mode == .atTime else {
            nextSetTime = nil
            scheduledTime = nil
            return context.mode == .whenIdle ? installWhenIdle(context) : nil
        }
        guard let due = nextSetTime, scheduledTime == context.time else {
            nextSetTime = context.time.nextDate(after: now, calendar: calendar)
            scheduledTime = context.time
            return nil
        }
        guard now >= due else { return nil }
        nextSetTime = context.time.nextDate(after: now, calendar: calendar)
        guard now.timeIntervalSince(due) < Self.lateness, context.blocker == nil else { return nil }
        checkingAtSetTime = true
        return .check
    }

    /// Called after each update check, with the context that already reflects its result.
    public mutating func checked(_ result: UpdateCheckResult, _ context: Context) -> Action? {
        let atSetTime = checkingAtSetTime
        checkingAtSetTime = false
        if case .failed = result { return nil }
        waitingForCheck = false
        switch context.mode {
        case .manual:
            return nil
        case .whenIdle:
            return installWhenIdle(context)
        case .atTime:
            guard atSetTime, context.activity != .busy, let release = installable(context) else { return nil }
            return .install(release, runsTimeout: context.runsTimeout)
        }
    }

    /// The drain gave up because agent runs were active: when idle, install again at the next idle moment without
    /// waiting for a check.
    public mutating func postponed() {
        waitingForCheck = false
    }

    private mutating func installWhenIdle(_ context: Context) -> Action? {
        guard !waitingForCheck, context.activity.isIdle, let release = installable(context) else { return nil }
        waitingForCheck = true
        return .install(release, runsTimeout: 0)
    }

    /// The release to install: available, not skipped, and updates allowed.
    private func installable(_ context: Context) -> Release? {
        guard context.blocker == nil, case let .available(release)? = context.offer else { return nil }
        return release
    }
}
