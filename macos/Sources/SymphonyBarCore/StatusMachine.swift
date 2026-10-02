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

/// Turns child process events and state polls into a `SymphonyStatus`.
public struct StatusMachine: Equatable {
    /// How often to poll while Symphony is starting, and otherwise.
    public static let startingPollInterval: TimeInterval = 1
    public static let pollInterval: TimeInterval = 5

    public enum Event: Equatable {
        /// The app started Symphony.
        case started
        /// The app's Symphony exited; `requested` is true when the app stopped it.
        case exited(ChildExit, requested: Bool)
        case polled(StatusPoll)
    }

    /// True while Symphony runs as the app's child process.
    public private(set) var ownsChild = false
    private var answeredSinceStart = false
    private var exitFailure: String?
    private var lastPoll: StatusPoll?

    public init() {}

    public mutating func handle(_ event: Event) {
        switch event {
        case .started:
            ownsChild = true
            answeredSinceStart = false
            exitFailure = nil
            lastPoll = nil
        case let .exited(exit, requested):
            ownsChild = false
            answeredSinceStart = false
            exitFailure = requested ? nil : "Symphony \(exit.summary)"
            // The last answer came from the process that just exited.
            lastPoll = nil
        case let .polled(poll):
            lastPoll = poll
            if case .state = poll {
                if ownsChild { answeredSinceStart = true }
                exitFailure = nil
            }
        }
    }

    public var status: SymphonyStatus {
        switch lastPoll {
        case let .state(snapshot)?:
            let external = !ownsChild
            return snapshot.pause == nil ? .running(snapshot, external: external) : .paused(snapshot, external: external)
        case let .failed(message)?:
            return .error(message)
        case .unreachable?, nil:
            if ownsChild {
                return answeredSinceStart ? .error("Symphony isn't answering") : .starting
            }
            return exitFailure.map(SymphonyStatus.error) ?? .stopped
        }
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
