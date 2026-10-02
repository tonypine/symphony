import Foundation
import SymphonyBarCore

/// Polls Symphony's `GET /api/v1/state`, one request at a time, waiting the interval it's given between polls.
@MainActor
final class StatusPoller {
    /// Called with each result; returns how long to wait before the next poll.
    var onPoll: ((StatusPoll) -> TimeInterval)?
    /// Symphony's state directory, looked up before each poll since Symphony rewrites its control URL on start.
    var stateRoot: () -> URL = { StateRoot.locate(environment: AppStores.current.environment) }

    private var timer: Timer?
    private var inFlight = false
    private var pollAgain = false
    // A background menu bar app gets App Nap, which would stretch a 5s timer to minutes.
    private var activity: NSObjectProtocol?

    func start() {
        activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Showing Symphony's status in the menu bar"
        )
        pollNow()
    }

    /// Polls straight away, for example after Symphony starts or exits.
    func pollNow() {
        timer?.invalidate()
        timer = nil
        guard !inFlight else {
            pollAgain = true
            return
        }
        inFlight = true
        Task {
            let result = await Self.fetch(stateRoot: stateRoot())
            inFlight = false
            let interval = onPoll?(result) ?? StatusMachine.pollInterval
            if pollAgain {
                pollAgain = false
                pollNow()
            } else if !inFlight {
                // onPoll may already have asked for the next poll.
                schedule(after: interval)
            }
        }
    }

    private func schedule(after interval: TimeInterval) {
        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: false) { _ in
            MainActor.assumeIsolated { self.pollNow() }
        }
        timer.tolerance = interval / 10
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Fetches Symphony's state from the URL in its control URL file.
    static func fetch(stateRoot: URL) async -> StatusPoll {
        let base = StateRoot.controlURL(in: stateRoot)
        let request = URLRequest(
            url: SymphonyState.stateURL(base: base),
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 2
        )
        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return .unreachable }
        return SymphonyState.poll(data: data, statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}
