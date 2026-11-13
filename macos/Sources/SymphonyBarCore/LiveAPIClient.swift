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

/// What a conditional GET got back (TP-1492): the answer and the `ETag` it carried, nil when it carried none.
public struct TaggedAnswer: Equatable {
    public let answer: APIAnswer
    public let etag: String?

    public init(_ answer: APIAnswer, etag: String? = nil) {
        self.answer = answer
        self.etag = etag
    }
}

/// What a conditional GET gave a view (TP-1492): a new answer with its tag, or `unchanged` when Symphony answered `304`
/// to the tag the view sent, so the view keeps what it shows and decodes nothing.
public enum ConditionalResult: Equatable {
    case changed(EndpointResult, etag: String?)
    case unchanged

    /// `tagged`, the answer to a read that sent `sent` in `If-None-Match`. A `304` is `unchanged` only when a tag was
    /// sent; the tag of an answer that isn't a `200` is dropped.
    public init(_ tagged: TaggedAnswer, sent: String?) {
        if sent != nil, case .answered(_, 304) = tagged.answer {
            self = .unchanged
            return
        }
        let result = EndpointResult(tagged.answer)
        if case .loaded = result {
            self = .changed(result, etag: tagged.etag)
        } else {
            self = .changed(result, etag: nil)
        }
    }
}

/// The tags of the answers a page shows, by path (TP-1492): each read sends the tag of the answer it holds, and a `304`
/// leaves the page as it is. A read that got no answer forgets the path's tag, so the next one reads in full.
public struct ConditionalReads: Equatable {
    /// What a read gives the page.
    public enum Read: Equatable {
        /// The new answer's body, nil when there is none (a 404, a failure).
        case changed(Data?)
        /// Nothing changed: the page keeps what it shows.
        case unchanged
    }

    public private(set) var tags: [String: String] = [:]

    public init() {}

    /// The tag to send with the read of `path`, nil when the page holds no answer of it.
    public func tag(for path: String) -> String? { tags[path] }

    /// Takes `result`, the answer to the read of `path`.
    public mutating func take(_ result: ConditionalResult, for path: String) -> Read {
        switch result {
        case .unchanged:
            return .unchanged
        case let .changed(.loaded(data), etag):
            tags[path] = etag
            return .changed(data)
        case .changed:
            tags[path] = nil
            return .changed(nil)
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
    /// How long a download may take, such as Audit's export of a busy week.
    public static let downloadTimeout: TimeInterval = 120

    /// Sends a GET for a path such as `api/v1/state`.
    public typealias Fetch = (_ path: String) async -> APIAnswer
    /// Sends a GET with `If-None-Match: ifNoneMatch` when given, and gives the answer's `ETag` back (TP-1492).
    public typealias ConditionalFetch = (_ path: String, _ ifNoneMatch: String?) async -> TaggedAnswer

    /// The last state payload Symphony served, as it came. A poll whose payload differs from it only in its
    /// `generated_at` publishes nothing (TP-1480), except once every `clockInterval`, so the minutes a view counts move
    /// on; `latestStateJSON` is the newest as it came.
    @Published public private(set) var stateJSON: Data?
    /// The parts of it Diagnostics reads, published only when they changed.
    @Published public private(set) var diagnostics: DiagnosticsPayload?
    /// The Overview's reading of it, decoded off the main actor and published only when it changed.
    @Published public private(set) var overviewState: OverviewState?
    /// The PR and CI watcher's reading of it, decoded off the main actor and published only when it changed.
    @Published public private(set) var watchState = WatchState()
    /// What the last state poll got when it got no payload, nil after one that did.
    @Published public private(set) var stateResult: EndpointResult?
    /// When the last state payload arrived: its own object, so only the views that show the time draw again each poll.
    public let heartbeat = StateHeartbeat()
    /// Each state payload that arrived, changed or not, after the client published what changed in it: what the window
    /// reads its other endpoints after. Not an event for the views.
    public let statePolled = PassthroughSubject<Data, Never>()
    /// The newest state payload as it came, whether or not it was published.
    public private(set) var latestStateJSON: Data?

    /// When the last state payload arrived.
    public var lastUpdate: Date? { heartbeat.lastUpdate }

    /// A state that changed only in its time is published again at most this often.
    public static let clockInterval: TimeInterval = 60
    /// The last payload published, without its time, and when it was.
    private var publishedContent: Data?
    private var publishedAt: Date?

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
    private let downloadFetch: Fetch
    private let conditionalFetch: ConditionalFetch
    private let scheduler: PollScheduler
    private let now: () -> Date
    private var timer: PollTimer?
    private(set) var pollTask: Task<Void, Never>?
    private var pollAgain = false
    private var started = false

    /// `download` reads a body that may take long to send, such as Audit's export; it defaults to `fetch`. `conditional`
    /// sends a read's tag; it defaults to `fetch`, which sends none and reads no tag back, so every read is in full.
    public init(
        fetch: @escaping Fetch,
        download: Fetch? = nil,
        conditional: ConditionalFetch? = nil,
        scheduler: PollScheduler = RunLoopScheduler(),
        now: @escaping () -> Date = Date.init
    ) {
        self.fetch = fetch
        downloadFetch = download ?? fetch
        conditionalFetch = conditional ?? { path, _ in TaggedAnswer(await fetch(path)) }
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

    /// A GET that sends `tag`, the `ETag` of the answer the view holds (TP-1492): `unchanged` when Symphony answers
    /// `304` to it, so nothing is sent or decoded while the answer is the same.
    public func get(_ path: String, ifNoneMatch tag: String?) async -> ConditionalResult {
        ConditionalResult(await conditionalFetch(path, tag), sent: tag)
    }

    /// The read of `path` through `reads`, which holds the tag of the answer the view shows and takes the new one.
    public func read(_ path: String, through reads: inout ConditionalReads) async -> ConditionalReads.Read {
        let result = await get(path, ifNoneMatch: reads.tag(for: path))
        return reads.take(result, for: path)
    }

    /// A GET's answer as it came, status code and all: what a screenshot's read tells apart (a 410 from a failure).
    public func answer(_ path: String) async -> APIAnswer {
        await fetch(path)
    }

    /// A pull request's page (D15), with a 404 of the page's own (an unknown repo or pull request) told apart from a
    /// Symphony that predates it.
    public func pullRequestPage(repoKey: String, number: Int) async -> PullRequestPageResult {
        PullRequestPageResult(await fetch(PullRequestPage.path(repoKey: repoKey, number: number)))
    }

    /// A GET for a long body, through the download fetch.
    public func download(_ path: String) async -> EndpointResult {
        EndpointResult(await downloadFetch(path))
    }

    private func poll() async {
        let answer = await fetch(Self.statePath)
        let read = await Task.detached(priority: .userInitiated) { StateRead(answer) }.value
        record(read)
        pollTask = nil
        if pollAgain {
            pollAgain = false
            refresh()
        } else {
            scheduleNext()
        }
    }

    private func record(_ read: StateRead) {
        guard let parts = read.parts else {
            if stateResult != read.failure { stateResult = read.failure }
            return
        }
        latestStateJSON = parts.data
        heartbeat.beat(now())
        if stateResult != nil { stateResult = nil }
        let changed = parts.content == nil || parts.content != publishedContent
        let clockDue = publishedAt.map { now().timeIntervalSince($0) >= Self.clockInterval } ?? true
        if changed || clockDue {
            publishedContent = parts.content
            publishedAt = now()
            stateJSON = parts.data
            if diagnostics != parts.diagnostics { diagnostics = parts.diagnostics }
            // The time alone moves only the minutes the views count: the Overview takes it with the clock.
            if changed ? !Self.sameOverview(overviewState, parts.overview) : overviewState != parts.overview {
                overviewState = parts.overview
            }
            if watchState != parts.watch { watchState = parts.watch }
        }
        statePolled.send(parts.data)
    }

    /// Whether two readings of the state say the same, whatever their `generated_at`.
    nonisolated static func sameOverview(_ lhs: OverviewState?, _ rhs: OverviewState?) -> Bool {
        guard var lhs, let rhs else { return lhs == nil && rhs == nil }
        lhs.generatedAt = rhs.generatedAt
        return lhs == rhs
    }

    private func scheduleNext() {
        timer?.cancel()
        timer = nil
        guard started else { return }
        timer = scheduler.schedule(after: interval) { [weak self] in self?.refresh() }
    }

    /// The state payload pretty-printed for the clipboard, or as it came when it isn't JSON.
    public var stateJSONText: String? {
        guard let stateJSON = latestStateJSON ?? stateJSON else { return nil }
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

    /// A conditional fetch through `transport` (TP-1492): the request carries `If-None-Match` when a tag is given, and
    /// the answer's `ETag` comes back with it. A request with its own validator gets Symphony's `304` as it came.
    public static func conditionalFetch(
        base: @escaping () -> URL?,
        transport: @escaping ControlAPI.Transport,
        timeout: TimeInterval = StatusMachine.pollTimeout
    ) -> ConditionalFetch {
        { path, tag in
            guard let base = base(), let url = url(path, base: base) else { return TaggedAnswer(.unreachable) }
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
            if let tag { request.setValue(tag, forHTTPHeaderField: "If-None-Match") }
            guard let (data, response) = try? await transport(request) else { return TaggedAnswer(.unreachable) }
            let http = response as? HTTPURLResponse
            return TaggedAnswer(.answered(data, statusCode: http?.statusCode ?? 0), etag: http?.value(forHTTPHeaderField: "ETag"))
        }
    }
}

/// When the client last read a state payload (TP-1480): the status bar's line and Diagnostics show it, and nothing
/// else draws again each poll.
@MainActor
public final class StateHeartbeat: ObservableObject {
    @Published public private(set) var lastUpdate: Date?

    public init() {}

    func beat(_ date: Date) { lastUpdate = date }
}

/// A state poll's answer, read off the main actor (TP-1480): why it holds no state, or the state's parts.
struct StateRead {
    /// The parts of a state payload the window reads, decoded once.
    struct Parts {
        var data: Data
        /// The payload without `generated_at`, as sorted JSON: two polls that differ only in their time give the same
        /// bytes. Nil when it isn't a JSON object.
        var content: Data?
        var diagnostics: DiagnosticsPayload
        var overview: OverviewState?
        var watch: WatchState
    }

    var failure: EndpointResult?
    var parts: Parts?

    init(_ answer: APIAnswer) {
        let result = EndpointResult(answer)
        guard case let .loaded(data) = result else {
            failure = result
            return
        }
        guard let payload = DiagnosticsPayload.decode(data) else {
            failure = .failed("Symphony sent a state that couldn't be read")
            return
        }
        // A snapshot Symphony couldn't take answers 200 with an error in place of the state.
        if let error = payload.error {
            failure = .failed(error.message ?? error.code ?? "Symphony reported an error")
            return
        }
        parts = Parts(
            data: data, content: Self.content(data), diagnostics: payload, overview: OverviewState.decode(data),
            watch: WatchState.decode(data)
        )
    }

    /// `data` without its `generated_at`, as sorted JSON; nil when it isn't a JSON object.
    static func content(_ data: Data) -> Data? {
        guard var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        object["generated_at"] = nil
        return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
