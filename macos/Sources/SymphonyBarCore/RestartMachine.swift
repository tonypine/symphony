import Foundation

/// The steps of a graceful restart, kept free of AppKit so they can be unit tested: check symphony.yml, pause
/// dispatch, wait until no agent run is active, stop, start, wait until Symphony answers, then resume dispatch
/// if the restart paused it. Events go in; the effects the app must carry out come back. An update drains the same
/// way but stops there, so the app can swap itself for the new version. The update never runs the new version's
/// Symphony: running it deletes older versions' unpacked releases, including the one the running Symphony loads
/// its modules from, so the new one only runs once the relaunched app starts it.
public struct RestartMachine: Equatable {
    /// How long a started Symphony has to answer on its control URL before the restart reports it.
    public static let answerTimeout: TimeInterval = 120

    public enum Purpose: Equatable {
        case restart
        /// Stop Symphony for an update instead of starting it again.
        case update
    }

    public enum Phase: Equatable {
        case idle
        /// Running `symphony check` on symphony.yml.
        case checkingConfig
        /// Asking Symphony to pause dispatch.
        case pausing
        /// Waiting until no agent run is active. `running` is nil until a poll shows dispatch paused.
        case waitingForRuns(running: Int?)
        case stopping
        case starting
        /// Symphony was started and hasn't answered on its control URL yet.
        case waitingForAnswer
        /// Asking Symphony to resume the dispatch the restart paused.
        case resuming
    }

    public enum Event: Equatable {
        case configChecked(ConfigCheckResult)
        case controlFinished(ControlAction, ControlResult)
        case polled(StatusPoll)
        /// The app's Symphony exited.
        case exited(ChildExit)
        /// Start returned; `error` says why it failed.
        case startFinished(error: String?)
        /// The user chose Restart Now Anyway.
        case restartNow
        /// The user chose Cancel Restart.
        case cancel
    }

    public enum Effect: Equatable {
        /// Run `symphony check --config <symphony.yml>` with the app's own Symphony, as Start would run it.
        case checkConfig
        case send(ControlAction)
        /// Poll Symphony's state now instead of waiting out the interval.
        case pollNow
        case stop
        case start
        case alert(title: String, message: String)
        /// An update's drain is done and Symphony has stopped; the app hands over to the new version.
        case stopped
    }

    /// Alert titles: before Symphony is stopped it keeps running, after that it may not have come back.
    public static let notRestartedTitle = "Symphony wasn't restarted"
    public static let failedTitle = "Symphony didn't come back"
    public static let notUpdatedTitle = "Symphony wasn't updated"

    public private(set) var phase: Phase = .idle
    public private(set) var purpose: Purpose = .restart
    /// True once the restart paused dispatch, so only it resumes; a pause the user made survives the restart.
    public private(set) var pausedByRestart = false
    /// True once the wait for agent runs has outlasted its timeout.
    public private(set) var offersRestartNow = false
    /// Why the last restart failed, shown in the menu until the next restart.
    public private(set) var error: String?

    private var alreadyPaused = false
    private var runsTimeout: TimeInterval = 0
    private var logPath = ""
    private var phaseStart = Date.distantPast

    public init() {}

    public var isRestarting: Bool { phase != .idle }

    /// Cancel Restart is offered while the restart waits for agent runs.
    public var canCancel: Bool {
        if case .waitingForRuns = phase { return true }
        return false
    }

    /// Starts a restart. `alreadyPaused` is whether dispatch is paused now. After `runsTimeout` seconds of waiting
    /// for agent runs the restart also offers Restart Now Anyway. An `.update` ends with `.stopped` instead of
    /// starting Symphony.
    /// Does nothing while a restart is under way.
    public mutating func begin(
        alreadyPaused: Bool,
        purpose: Purpose = .restart,
        runsTimeout: TimeInterval,
        logPath: String,
        now: Date = Date()
    ) -> [Effect] {
        guard phase == .idle else { return [] }
        self = RestartMachine()
        self.purpose = purpose
        self.alreadyPaused = alreadyPaused
        self.runsTimeout = runsTimeout
        self.logPath = logPath
        enter(.checkingConfig, now: now)
        return [.checkConfig]
    }

    public mutating func handle(_ event: Event, now: Date = Date()) -> [Effect] {
        switch (phase, event) {
        case let (.checkingConfig, .configChecked(result)):
            return configChecked(result, now: now)

        case let (.pausing, .controlFinished(.pause, .failed(message))):
            return fail(notDoneTitle, "\(message)\n\nSymphony keeps running.", now: now)

        case (.pausing, .controlFinished(.pause, .done)):
            pausedByRestart = true
            enter(.waitingForRuns(running: nil), now: now)
            return [.pollNow]

        case let (.waitingForRuns, .polled(poll)):
            return waitedForRuns(poll, now: now)

        case (.waitingForRuns, .restartNow) where offersRestartNow:
            enter(.stopping, now: now)
            return [.stop]

        case (.waitingForRuns, .cancel):
            guard pausedByRestart else {
                enter(.idle, now: now)
                return []
            }
            enter(.resuming, now: now)
            return [.send(.resume)]

        case (.stopping, .exited):
            if purpose == .update {
                enter(.idle, now: now)
                return [.stopped]
            }
            enter(.starting, now: now)
            return [.start]

        case let (.starting, .startFinished(startError)):
            guard let startError else {
                enter(.waitingForAnswer, now: now)
                return []
            }
            return fail(Self.failedTitle, "Couldn't start Symphony: \(startError)\(pauseNote)", now: now)

        case let (.waitingForAnswer, .polled(poll)):
            if case .state = poll {
                guard pausedByRestart else {
                    enter(.idle, now: now)
                    return []
                }
                enter(.resuming, now: now)
                return [.send(.resume)]
            }
            guard now.timeIntervalSince(phaseStart) >= Self.answerTimeout else { return [] }
            let seconds = Int(Self.answerTimeout)
            return fail(
                Self.failedTitle,
                "Symphony didn't answer within \(seconds) seconds of starting. See \(logPath).\(pauseNote)",
                now: now
            )

        case let (.starting, .exited(exit)), let (.waitingForAnswer, .exited(exit)):
            return fail(Self.failedTitle, "Symphony \(exit.summary) before it answered. See \(logPath).\(pauseNote)", now: now)

        case let (.resuming, .controlFinished(.resume, result)):
            enter(.idle, now: now)
            if case let .failed(message) = result { error = message }
            return []

        case let (.checkingConfig, .exited(exit)), let (.pausing, .exited(exit)), let (.waitingForRuns, .exited(exit)):
            // Symphony went away on its own; there is nothing left to restart gracefully.
            enter(.idle, now: now)
            error = "\(purpose == .update ? "Update" : "Restart") cancelled: Symphony \(exit.summary)"
            return []

        default:
            return []
        }
    }

    /// The line the menu shows for the restart: its progress, or why it failed.
    public var menuLine: String? {
        let doing = purpose == .update ? "Updating" : "Restarting"
        switch phase {
        case .idle:
            return error
        case .checkingConfig:
            return "\(doing): checking symphony.yml…"
        case .pausing:
            return "\(doing): pausing dispatch…"
        case .waitingForRuns(running: nil):
            return "\(doing): waiting for dispatch to pause…"
        case let .waitingForRuns(running: count?):
            return count == 1 ? "Waiting for 1 agent run…" : "Waiting for \(count) agent runs…"
        case .stopping:
            return "\(doing): stopping Symphony…"
        case .starting, .waitingForAnswer:
            return "\(doing): waiting for Symphony to answer…"
        case .resuming:
            return "\(doing): resuming dispatch…"
        }
    }

    private mutating func configChecked(_ result: ConfigCheckResult, now: Date) -> [Effect] {
        if case let .failed(message) = result {
            return fail(notDoneTitle, "\(message)\n\nSymphony keeps running.", now: now)
        }
        guard alreadyPaused else {
            enter(.pausing, now: now)
            return [.send(.pause)]
        }
        enter(.waitingForRuns(running: nil), now: now)
        return [.pollNow]
    }

    private mutating func waitedForRuns(_ poll: StatusPoll, now: Date) -> [Effect] {
        // Only a poll that shows dispatch paused was taken after the pause, so its count can't grow any more.
        if case let .state(snapshot) = poll, snapshot.pause != nil {
            guard snapshot.running > 0 else {
                enter(.stopping, now: now)
                return [.stop]
            }
            phase = .waitingForRuns(running: snapshot.running)
        } else if case .state = poll, !pausedByRestart {
            // The pause the restart counted on is gone (the menu's status was older than a resume), so pause now.
            enter(.pausing, now: now)
            return [.send(.pause)]
        }
        if now.timeIntervalSince(phaseStart) >= runsTimeout { offersRestartNow = true }
        return []
    }

    private mutating func fail(_ title: String, _ message: String, now: Date) -> [Effect] {
        enter(.idle, now: now)
        error = message.components(separatedBy: "\n").first
        return [.alert(title: title, message: message)]
    }

    private mutating func enter(_ phase: Phase, now: Date) {
        self.phase = phase
        phaseStart = now
        offersRestartNow = false
    }

    /// Before Symphony is stopped, a failed restart or update leaves it running.
    private var notDoneTitle: String {
        purpose == .update ? Self.notUpdatedTitle : Self.notRestartedTitle
    }

    /// Added to failures after the stop: a pause the restart made is kept by Symphony, so say so.
    private var pauseNote: String {
        pausedByRestart ? "\n\nDispatch stays paused; choose Resume Dispatch once Symphony runs." : ""
    }
}
