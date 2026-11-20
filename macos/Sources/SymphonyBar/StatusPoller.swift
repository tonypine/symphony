import Foundation
import SymphonyBarCore

/// Polls Symphony's `GET /api/v1/state`, one request at a time, waiting the interval it's given between polls.
///
/// A slow state read is not a missing Symphony (TP-1562): the request waits up to `StatusMachine.stateReadTimeout`, and
/// its answer counts whenever it arrives. Every `StatusMachine.pollTimeout` it waits, it reports a late poll, with
/// whether Symphony's light health read answers meanwhile; so does a state read that fails.
@MainActor
final class StatusPoller {
    /// Called with each result and, for a late or failed read, whether the health read answered; returns how long to
    /// wait before the next poll.
    var onPoll: ((StatusPoll, Bool?) -> TimeInterval)?
    /// Called each time the state read in flight is late, with whether the health read answered.
    var onLate: ((Bool) -> Void)?
    /// Symphony's state directory, looked up before each poll since Symphony rewrites its control URL on start.
    var stateRoot: () -> URL = { StateRoot.locate(environment: AppStores.current.environment) }

    private var timer: Timer?
    private var lateTimer: Timer?
    private var inFlight = false
    private var pollAgain = false
    /// Counts the state reads, so a late tick of an earlier one is dropped.
    private var generation = 0
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
        generation += 1
        let root = stateRoot()
        scheduleLate(generation: generation, stateRoot: root)
        Task {
            let result = await Self.fetch(stateRoot: root, timeout: StatusMachine.stateReadTimeout)
            var health: Bool?
            if case .unreachable = result { health = await Self.fetchHealth(stateRoot: root) }
            lateTimer?.invalidate()
            lateTimer = nil
            inFlight = false
            let interval = onPoll?(result, health) ?? StatusMachine.pollInterval
            if pollAgain {
                pollAgain = false
                pollNow()
            } else if !inFlight {
                // onPoll may already have asked for the next poll.
                schedule(after: interval)
            }
        }
    }

    /// Reports the read of `generation` late each `pollTimeout` while it is still in flight.
    private func scheduleLate(generation: Int, stateRoot: URL) {
        lateTimer?.invalidate()
        let timer = Timer(timeInterval: StatusMachine.pollTimeout, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard self.inFlight, self.generation == generation else { return }
                Task {
                    let health = await Self.fetchHealth(stateRoot: stateRoot)
                    guard self.inFlight, self.generation == generation else { return }
                    self.onLate?(health)
                }
            }
        }
        timer.tolerance = StatusMachine.pollTimeout / 10
        RunLoop.main.add(timer, forMode: .common)
        lateTimer = timer
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

    /// Fetches Symphony's state from the URL in its control URL file. In QA mode nothing answers until Symphony has
    /// written one, unless API fixtures answer.
    static func fetch(stateRoot: URL, timeout: TimeInterval = StatusMachine.pollTimeout) async -> StatusPoll {
        let stores = AppStores.current
        guard let base = StateRoot.controlURL(in: stateRoot, fallback: stores.apiFallback) else {
            return .unreachable
        }
        let request = URLRequest(
            url: SymphonyState.stateURL(base: base),
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: timeout
        )
        guard let (data, response) = try? await stores.apiTransport(request) else { return .unreachable }
        return SymphonyState.poll(data: data, statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    /// Whether Symphony's light health read answers: any HTTP answer is a Symphony that is alive (TP-1562).
    static func fetchHealth(stateRoot: URL) async -> Bool {
        let stores = AppStores.current
        guard let base = StateRoot.controlURL(in: stateRoot, fallback: stores.apiFallback) else { return false }
        let request = URLRequest(
            url: SymphonyState.healthURL(base: base),
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: StatusMachine.healthTimeout
        )
        guard let (_, response) = try? await stores.apiTransport(request) else { return false }
        return response is HTTPURLResponse
    }

    /// Fetches Symphony's drain read, which answers when its state fails (TP-1550); nil when it doesn't answer one.
    static func fetchDrain(stateRoot: URL) async -> DrainStatus? {
        let stores = AppStores.current
        guard let base = StateRoot.controlURL(in: stateRoot, fallback: stores.apiFallback) else { return nil }
        let request = URLRequest(
            url: DrainStatus.url(base: base),
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: StatusMachine.pollTimeout
        )
        guard let (data, response) = try? await stores.apiTransport(request) else { return nil }
        return DrainStatus.parse(data: data, statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}
