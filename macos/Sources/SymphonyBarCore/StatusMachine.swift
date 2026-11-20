import Foundation

/// What the menu bar shows about Symphony.
public enum SymphonyStatus: Equatable {
    case stopped
    /// The app started Symphony and it hasn't answered yet.
    case starting
    /// `external` is true when Symphony wasn't started by this app, for example from the CLI.
    case running(StateSnapshot, external: Bool)
    case paused(StateSnapshot, external: Bool)
    case error(String)
}

/// Turns child process events, state polls and health checks into a `SymphonyStatus`.
///
/// A slow Symphony is not a stopped one (TP-1562): while the Symphony the app started is alive, the status keeps its
/// last state answer, so the window keeps its pages, and `lag` says it isn't current. Whether Symphony answers at all
/// comes from its light health read, not from the state read, which can take seconds under load.
public struct StatusMachine: Equatable {
    /// How often to poll while Symphony is starting, and otherwise.
    public static let startingPollInterval: TimeInterval = 1
    public static let pollInterval: TimeInterval = 5
    /// How long a state poll waits before it counts as late: the poll keeps waiting, and a late answer still counts.
    public static let pollTimeout: TimeInterval = 5
    /// How long the menu bar's state read waits for Symphony's answer before it gives up on it.
    public static let stateReadTimeout: TimeInterval = 60
    /// How long the health read waits: it answers in milliseconds from a Symphony that is alive.
    public static let healthTimeout: TimeInterval = 3
    /// Late polls in a row before the window says Symphony isn't answering: with the interval, about 10 s without a
    /// state. A single late poll is a slow answer, for example a busy snapshot. For an external Symphony, the polls
    /// whose health read didn't answer either count the same way before it shows as stopped and Start is offered, so
    /// a busy one that still holds the control URL isn't joined by a second Symphony.
    public static let missedPollsBeforeError = 2
    /// The status line's words while Symphony doesn't answer its state.
    public static let notAnsweringTitle = "Symphony isn't answering"

    public enum Event: Equatable {
        /// The app started Symphony.
        case started
        /// The app's Symphony exited; `requested` is true when the app stopped it.
        case exited(ChildExit, requested: Bool)
        /// A state poll's answer, or `.unreachable` for one that didn't answer in time.
        case polled(StatusPoll)
        /// Whether Symphony's health read answered, checked before the late poll it comes with.
        case health(answering: Bool)
    }

    /// True while Symphony runs as the app's child process.
    public private(set) var ownsChild = false
    private var exitFailure: String?
    /// The last state Symphony answered: from the Symphony the app started, or from the external one found.
    private var snapshot: StateSnapshot?
    /// The last answer the app couldn't read, until the next state.
    private var failure: String?
    /// When Symphony last answered its state, and last answered at all (its state, an answer, or its health read).
    private var stateAt: Date?
    private var answeredAt: Date?
    /// State polls in a row that didn't answer, and of those the ones whose health read didn't answer either.
    private var latePolls = 0
    private var missedPolls = 0
    /// The health read checked for the next late poll, nil when none was.
    private var healthAnswered: Bool?
    /// Whether the not-answering notification went out since Symphony last answered.
    private var alerted = false

    public init() {}

    public mutating func handle(_ event: Event, at now: Date = Date()) {
        switch event {
        case .started:
            self = StatusMachine()
            ownsChild = true
        case let .exited(exit, requested):
            // The last answer came from the process that just exited.
            self = StatusMachine()
            exitFailure = requested ? nil : "Symphony \(exit.summary)"
        case let .health(answering):
            healthAnswered = answering
        case let .polled(poll):
            handlePoll(poll, at: now)
        }
    }

    private mutating func handlePoll(_ poll: StatusPoll, at now: Date) {
        let health = healthAnswered
        healthAnswered = nil
        switch poll {
        case let .state(state):
            snapshot = state
            failure = nil
            exitFailure = nil
            answered(at: now)
            stateAt = now
        case let .failed(message):
            failure = message
            answered(at: now)
        case .unreachable:
            latePolls += 1
            if health == true {
                // Symphony is alive, only slow to give its state.
                missedPolls = 0
                answeredAt = now
                alerted = false
            } else {
                missedPolls += 1
            }
            // An external Symphony that stopped answering is gone: Start is offered.
            if !ownsChild, missedPolls >= Self.missedPollsBeforeError {
                snapshot = nil
                failure = nil
            }
        }
    }

    private mutating func answered(at now: Date) {
        latePolls = 0
        missedPolls = 0
        answeredAt = now
        alerted = false
    }

    public var status: SymphonyStatus {
        if let snapshot {
            let external = !ownsChild
            return snapshot.pause == nil ? .running(snapshot, external: external) : .paused(snapshot, external: external)
        }
        if let failure { return .error(failure) }
        // The Symphony the app started hasn't answered its state yet.
        if ownsChild { return .starting }
        return exitFailure.map(SymphonyStatus.error) ?? .stopped
    }

    /// True while the last state answer is still shown although Symphony missed the latest poll, before the window
    /// says it isn't answering.
    public var slowToAnswer: Bool {
        snapshot != nil && latePolls > 0 && latePolls < Self.missedPollsBeforeError
    }

    /// Why the status's state isn't current, for the window's status line: "Symphony isn't answering · 25 s" once
    /// Symphony missed enough polls in a row, or the message of the answer the app couldn't read. Nil while the state
    /// is current, or when there is no state to keep showing.
    public func lag(now: Date = Date()) -> String? {
        guard snapshot != nil else { return nil }
        if latePolls >= Self.missedPollsBeforeError, let stateAt {
            return "\(Self.notAnsweringTitle) · \(Self.duration(now.timeIntervalSince(stateAt)))"
        }
        return failure
    }

    /// True once Symphony, still shown from its last answer, hasn't answered even its health read for `limit`
    /// seconds: the menu bar shows the problem.
    public func notAnswering(now: Date = Date(), limit: TimeInterval) -> Bool {
        guard snapshot != nil, missedPolls > 0, let answeredAt else { return false }
        return now.timeIntervalSince(answeredAt) >= limit
    }

    /// True the first time `notAnswering` holds since Symphony last answered: the one notification it sends.
    public mutating func takeNotAnsweringAlert(now: Date = Date(), limit: TimeInterval) -> Bool {
        guard !alerted, notAnswering(now: now, limit: limit) else { return false }
        alerted = true
        return true
    }

    /// How long Symphony hasn't answered, for the menu's line and the notification: "1 min" or "45 s".
    public func silence(now: Date = Date()) -> String? {
        answeredAt.map { Self.duration(now.timeIntervalSince($0)) }
    }

    /// "25 s" under a minute, else "3 min".
    static func duration(_ seconds: TimeInterval) -> String {
        let seconds = max(Int(seconds.rounded()), 0)
        return seconds < 60 ? "\(seconds) s" : "\(seconds / 60) min"
    }

    /// Seconds until the next poll: quicker while Symphony is starting.
    public var nextPollInterval: TimeInterval {
        status == .starting ? Self.startingPollInterval : Self.pollInterval
    }

    /// Start is offered unless Symphony is already running, as the app's child or externally.
    public var canStart: Bool {
        guard !ownsChild else { return false }
        switch status {
        case .running, .paused:
            return false
        case .stopped, .starting, .error:
            return true
        }
    }

    /// Stop only applies to a Symphony the app started; an external one is left alone.
    public var canStop: Bool { ownsChild }
}
