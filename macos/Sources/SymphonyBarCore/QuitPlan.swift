import Foundation

/// What a quit does before the app exits: the decision behind `applicationShouldTerminate`.
///
/// A quit after the app stopped Symphony itself to quit (an update's hand-off, a rollback) ends at once and sends
/// nothing: there is no Symphony left to take a held Inbox answer or a ticket page's look, and waiting on one held
/// the quit forever (TP-1475).
public struct QuitPlan: Equatable {
    /// Whether the app runs Symphony and must stop it before it exits.
    public let stopsSymphony: Bool
    /// Whether the Inbox answer held for Undo is sent first.
    public let sendsHeldAnswer: Bool
    /// Whether the look of the ticket page shown is sent first.
    public let sendsLook: Bool
    /// Whether to ask before quitting, for the agent runs a stop ends.
    public let confirmsActiveRuns: Bool

    /// How long a send at quit may take before the quit goes on without its answer.
    public static let sendTimeout: TimeInterval = 3

    /// Nothing to send or stop: the app exits now.
    public var endsNow: Bool { !stopsSymphony && !sendsHeldAnswer && !sendsLook }

    public init(
        symphonyRunning: Bool,
        symphonyStopping: Bool,
        stoppedToQuit: Bool,
        holdsAnswer: Bool,
        holdsLook: Bool
    ) {
        stopsSymphony = symphonyRunning
        // A Symphony the app doesn't run may still answer; one the app stopped to quit doesn't.
        let canSend = !stoppedToQuit || symphonyRunning
        sendsHeldAnswer = canSend && holdsAnswer
        sendsLook = canSend && holdsLook
        confirmsActiveRuns = symphonyRunning && !symphonyStopping
    }
}

/// Waits for async work with a deadline.
public enum Bounded {
    /// Runs `operation` and waits for it at most `seconds`. Returns true when it finished in time; otherwise the
    /// caller goes on and the operation is left to finish, or not, on its own.
    @discardableResult
    public static func wait(seconds: TimeInterval, for operation: @escaping @Sendable () async -> Void) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let once = Once(continuation)
            Task { await operation(); once.resume(true) }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * 1_000_000_000))
                once.resume(false)
            }
        }
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bool, Never>?

        init(_ continuation: CheckedContinuation<Bool, Never>) {
            self.continuation = continuation
        }

        func resume(_ value: Bool) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: value)
        }
    }
}

/// The completions waiting for Symphony to exit. A stop asked for once Symphony has already exited completes at
/// once instead of waiting for an exit that already came.
public struct StopWaiters {
    private var waiting: [() -> Void] = []

    public init() {}

    /// Whether any completion waits.
    public var isEmpty: Bool { waiting.isEmpty }

    /// Adds `completion` while Symphony runs, or runs it now when it doesn't. Returns true when Symphony runs and
    /// still has to be told to stop.
    public mutating func add(_ completion: (() -> Void)?, running: Bool) -> Bool {
        guard running else {
            completion?()
            return false
        }
        if let completion { waiting.append(completion) }
        return true
    }

    /// Symphony exited: hands over every completion, once, for the caller to run. They run outside this value, so
    /// one that stops Symphony again doesn't change it while it is read.
    public mutating func exited() -> [() -> Void] {
        let completions = waiting
        waiting = []
        return completions
    }
}

/// A flag read and written from any thread.
public final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool

    public init(_ value: Bool = false) {
        self.value = value
    }

    public var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    public func set(_ newValue: Bool) {
        lock.lock()
        value = newValue
        lock.unlock()
    }
}
