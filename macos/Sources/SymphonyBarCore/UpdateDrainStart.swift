import Foundation

/// The drain read the app keeps while its Symphony's state fails to load: taken after each such poll, it says what
/// an update starts from when the state can't (TP-1550). Any other poll forgets it.
public struct FailedStateDrainRead: Equatable {
    public private(set) var read: DrainStatus?

    public init() {}

    /// After a poll: whether to read Symphony's drain request now. Only a poll whose state failed to load, from the
    /// app's own Symphony and with no drain under way (a drain reads it itself), asks for one; any other poll forgets
    /// the last read.
    public mutating func polled(_ poll: StatusPoll, symphonyRunning: Bool, restarting: Bool) -> Bool {
        guard case .failed = poll, symphonyRunning, !restarting else {
            read = nil
            return false
        }
        return true
    }

    /// The read asked for came back. It is kept only while the state still fails to load, and the return says so.
    public mutating func received(_ drain: DrainStatus?, status: SymphonyStatus) -> Bool {
        guard case .error = status else { return false }
        read = drain
        return true
    }

    /// The read, while `status` says the state failed to load.
    public func current(status: SymphonyStatus) -> DrainStatus? {
        guard case .error = status else { return nil }
        return read
    }
}

/// How an update's drain starts, from Symphony's status as the app's last poll saw it and the drain read kept
/// while its state fails to load (TP-1550).
public enum UpdateDrainStart: Equatable {
    /// The app doesn't run Symphony: nothing to drain, the update hands over at once.
    case nothingToDrain
    /// Symphony is starting, stopping or restarting, or its runs are unknown: the update fails with `refusal`.
    case refused
    /// Pause dispatch unless `alreadyPaused`, wait for agent runs, then stop Symphony.
    case drain(alreadyPaused: Bool)

    public static let refusal = "Symphony is starting, stopping or restarting; try again once it runs."
    public static let nothingToDrainLog = "Symphony isn't running from the app; nothing to drain"
    public static let doneLog = "drain done: agent runs finished and Symphony stopped"

    public init(
        status: SymphonyStatus,
        symphonyRunning: Bool,
        symphonyStarting: Bool,
        symphonyStopping: Bool,
        restarting: Bool,
        drain: DrainStatus?
    ) {
        guard !symphonyStarting else {
            self = .refused
            return
        }
        guard symphonyRunning else {
            self = .nothingToDrain
            return
        }
        guard !restarting, !symphonyStopping, Self.drainable(status: status, drain: drain) else {
            self = .refused
            return
        }
        self = .drain(alreadyPaused: StatusMenu.canResume(status) || drain?.paused == true)
    }

    /// Whether Install Update is offered for Symphony's `status`, as far as Symphony goes.
    public static func canInstall(status: SymphonyStatus, symphonyRunning: Bool, drain: DrainStatus?) -> Bool {
        !symphonyRunning || drainable(status: status, drain: drain)
    }

    /// The update log's line as the drain starts.
    public var startLog: String? {
        guard case let .drain(alreadyPaused) = self else { return nil }
        return (alreadyPaused ? "dispatch already paused" : "pausing dispatch")
            + "; waiting for agent runs, then stopping Symphony"
    }

    /// A Symphony the app runs that answers with its state, or whose state fails to load but whose drain read
    /// answered.
    private static func drainable(status: SymphonyStatus, drain: DrainStatus?) -> Bool {
        if StatusMenu.canRestart(status) { return true }
        guard case .error = status else { return false }
        return drain != nil
    }
}
