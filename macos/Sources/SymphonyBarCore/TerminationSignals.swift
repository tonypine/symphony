import Darwin
import Dispatch

/// Calls a handler on `queue` for SIGTERM, SIGINT and SIGHUP instead of letting them kill the process.
///
/// AppKit doesn't call `applicationShouldTerminate` when the app gets a signal (a `kill`, logout, or a terminal
/// closing), so without this the app would exit and leave its Symphony child, and the child's agents, running.
public final class TerminationSignals {
    public static let defaultSignals: [Int32] = [SIGTERM, SIGINT, SIGHUP]

    /// Ends the process without `queue` when the handler hasn't, `after` seconds after a signal, provided `canExit`
    /// says nothing is left to stop. It covers a `queue` that is stuck, as the main queue was when a quit waited
    /// inside one of its own blocks (TP-1475): the app then still ends on a `kill` once Symphony has stopped.
    public struct Fallback {
        public let after: TimeInterval
        public let canExit: @Sendable () -> Bool
        public let exit: @Sendable (Int32) -> Void

        public init(
            after: TimeInterval,
            canExit: @escaping @Sendable () -> Bool,
            exit: @escaping @Sendable (Int32) -> Void = { TerminationSignals.exit(as: $0) }
        ) {
            self.after = after
            self.canExit = canExit
            self.exit = exit
        }
    }

    private let signals: [Int32]
    private var sources: [DispatchSourceSignal] = []
    /// Receives the signals, so they arrive while `queue` is stuck.
    private let receiver = DispatchQueue(label: "TerminationSignals")

    /// Starts handling `signals`, calling `handler` on `queue`. Their default action stays off until `cancel`.
    public init(
        signals: [Int32] = defaultSignals,
        queue: DispatchQueue,
        fallback: Fallback? = nil,
        handler: @escaping (Int32) -> Void
    ) {
        self.signals = signals
        for number in signals {
            // The default action would end the process before the source could run.
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: receiver)
            source.setEventHandler { [receiver] in
                queue.async { handler(number) }
                guard let fallback else { return }
                receiver.asyncAfter(deadline: .now() + fallback.after) {
                    if fallback.canExit() { fallback.exit(number) }
                }
            }
            source.resume()
            sources.append(source)
        }
    }

    /// Stops handling the signals and gives them back their default action.
    public func cancel() {
        sources.forEach { $0.cancel() }
        sources = []
        signals.forEach { signal($0, SIG_DFL) }
    }

    /// Ends the process as `signal` would have, so the parent sees the usual status.
    public static func exit(as number: Int32) -> Never {
        signal(number, SIG_DFL)
        raise(number)
        Darwin.exit(128 + number)
    }
}
