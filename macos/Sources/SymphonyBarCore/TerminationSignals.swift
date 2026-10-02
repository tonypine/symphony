import Darwin
import Dispatch

/// Calls a handler on `queue` for SIGTERM, SIGINT and SIGHUP instead of letting them kill the process.
///
/// AppKit doesn't call `applicationShouldTerminate` when the app gets a signal (a `kill`, logout, or a terminal
/// closing), so without this the app would exit and leave its Symphony child, and the child's agents, running.
public final class TerminationSignals {
    public static let defaultSignals: [Int32] = [SIGTERM, SIGINT, SIGHUP]

    private let signals: [Int32]
    private var sources: [DispatchSourceSignal] = []

    /// Starts handling `signals`. Their default action stays off until `cancel`.
    public init(signals: [Int32] = defaultSignals, queue: DispatchQueue, handler: @escaping (Int32) -> Void) {
        self.signals = signals
        for number in signals {
            // The default action would end the process before the source could run.
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
            source.setEventHandler { handler(number) }
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
