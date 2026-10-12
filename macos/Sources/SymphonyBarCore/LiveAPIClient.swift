import Combine
import Foundation

/// Schedules the client's next poll; a `Timer` in the app, a manual clock in tests.
public protocol PollScheduler {
    func schedule(after interval: TimeInterval, _ action: @escaping @MainActor () -> Void) -> PollTimer
}

public protocol PollTimer {
    func cancel()
}

/// A `PollScheduler` on the main run loop.
public struct RunLoopScheduler: PollScheduler {
    public init() {}

    public func schedule(after interval: TimeInterval, _ action: @escaping @MainActor () -> Void) -> PollTimer {
        let timer = Timer(timeInterval: interval, repeats: false) { _ in
            MainActor.assumeIsolated { action() }
        }
        timer.tolerance = interval / 10
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }
}

extension Timer: PollTimer {
    public func cancel() { invalidate() }
}

/// What a GET to Symphony's local API got back.
public enum APIAnswer: Equatable {
    case answered(Data, statusCode: Int)
    /// Nothing answered, or there is no control URL yet.
    case unreachable
}

/// What a view's endpoint gave it.
public enum EndpointResult: Equatable {
    case loaded(Data)
    /// The endpoint answered 404: the Symphony running predates it (`EndpointPlaceholder.updateSymphony`).
    case unsupported
    case failed(String)

    public init(_ answer: APIAnswer) {
        switch answer {
        case let .answered(data, 200):
            self = .loaded(data)
        case .answered(_, 404):
            self = .unsupported
        case let .answered(_, statusCode):
            self = .failed("Symphony answered with HTTP \(statusCode)")
        case .unreachable:
            self = .failed("Symphony isn't answering")
        }
    }
}

/// The one client every view of the Symphony window reads Symphony's local API through (DD5, P7). It polls
/// `GET /api/v1/state` every 2 s while the window is visible and every 30 s otherwise, one request at a time.
@MainActor
public final class LiveAPIClient: ObservableObject {
    public static let statePath = "api/v1/state"
    public static let visibleInterval: TimeInterval = 2
    public static let hiddenInterval: TimeInterval = 30

    /// Sends a GET for a path such as `api/v1/state`.
    public typealias Fetch = (_ path: String) async -> APIAnswer

    /// The last state payload Symphony served, as it came.
    @Published public private(set) var stateJSON: Data?
    /// The parts of it Diagnostics reads.
    @Published public private(set) var diagnostics: DiagnosticsPayload?
    /// When the last state payload arrived.
    @Published public private(set) var lastUpdate: Date?
    /// What the last state poll got when it got no payload, nil after one that did.
    @Published public private(set) var stateResult: EndpointResult?

    /// Whether the window is on screen; polls quicken while it is.
    public var isVisible = false {
        didSet {
            guard isVisible != oldValue else { return }
            // Fresh values straight away when the window shows; only a slower timer when it hides.
            guard started else { return }
            if isVisible { refresh() } else if pollTask == nil { scheduleNext() }
        }
    }

    public var interval: TimeInterval { isVisible ? Self.visibleInterval : Self.hiddenInterval }

    private let fetch: Fetch
    private let scheduler: PollScheduler
    private let now: () -> Date
    private var timer: PollTimer?
    private(set) var pollTask: Task<Void, Never>?
    private var pollAgain = false
    private var started = false

    public init(fetch: @escaping Fetch, scheduler: PollScheduler = RunLoopScheduler(), now: @escaping () -> Date = Date.init) {
        self.fetch = fetch
        self.scheduler = scheduler
        self.now = now
    }

    /// Starts polling, with a poll straight away.
    public func start() {
        guard !started else { return }
        started = true
        refresh()
    }

    /// Stops polling until the next `start()`.
    public func stop() {
        started = false
        timer?.cancel()
        timer = nil
    }

    /// Polls now (⌘R, or after a control action), or right after the poll in flight.
    @discardableResult
    public func refresh() -> Task<Void, Never> {
        timer?.cancel()
        timer = nil
        if let pollTask {
            pollAgain = true
            return pollTask
        }
        let task = Task { await self.poll() }
        pollTask = task
        return task
    }

    /// A GET for a view's own endpoint, shared by every view.
    public func get(_ path: String) async -> EndpointResult {
        EndpointResult(await fetch(path))
    }

    private func poll() async {
        let answer = await fetch(Self.statePath)
        record(answer)
        pollTask = nil
        if pollAgain {
            pollAgain = false
            refresh()
        } else {
            scheduleNext()
        }
    }

    private func record(_ answer: APIAnswer) {
        let result = EndpointResult(answer)
        guard case let .loaded(data) = result else {
            stateResult = result
            return
        }
        guard let payload = DiagnosticsPayload.decode(data) else {
            stateResult = .failed("Symphony sent a state that couldn't be read")
            return
        }
        // A snapshot Symphony couldn't take answers 200 with an error in place of the state.
        if let error = payload.error {
            stateResult = .failed(error.message ?? error.code ?? "Symphony reported an error")
            return
        }
        stateJSON = data
        diagnostics = payload
        lastUpdate = now()
        stateResult = nil
    }

    private func scheduleNext() {
        timer?.cancel()
        timer = nil
        guard started else { return }
        timer = scheduler.schedule(after: interval) { [weak self] in self?.refresh() }
    }

    /// The state payload pretty-printed for the clipboard, or as it came when it isn't JSON.
    public var stateJSONText: String? {
        guard let stateJSON else { return nil }
        if let object = try? JSONSerialization.jsonObject(with: stateJSON),
           let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) {
            return String(decoding: pretty, as: UTF8.self)
        }
        return String(decoding: stateJSON, as: UTF8.self)
    }

    /// `path` under `base`, with the query after its `?` kept as a query (`api/v1/audit?issue=SHOP-305`).
    nonisolated public static func url(_ path: String, base: URL) -> URL? {
        let parts = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let url = base.appendingPathComponent(String(parts[0]))
        guard parts.count == 2 else { return url }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.percentEncodedQuery = String(parts[1])
        return components?.url
    }

    /// A fetch through `transport` to the control URL `base()` gives, or unreachable while there is none.
    public static func fetch(
        base: @escaping () -> URL?,
        transport: @escaping ControlAPI.Transport,
        timeout: TimeInterval = StatusMachine.pollTimeout
    ) -> Fetch {
        { path in
            guard let base = base(), let url = url(path, base: base) else { return .unreachable }
            let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
            guard let (data, response) = try? await transport(request) else { return .unreachable }
            return .answered(data, statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }
}
