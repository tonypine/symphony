import Combine
import Foundation

/// One message of a server-sent events stream: its `event` name (`message` when it names none), its data lines
/// joined with newlines, and the last `id` the stream gave.
public struct ServerSentEvent: Equatable {
    public var event: String
    public var data: String
    public var id: String?

    public init(event: String = "message", data: String, id: String? = nil) {
        self.event = event
        self.data = data
        self.id = id
    }
}

/// What a server-sent events stream holds: messages, and the comment lines a server sends to keep it open.
public enum ServerSentEventItem: Equatable {
    case event(ServerSentEvent)
    case comment(String)
}

/// Reads the server-sent events format (the WHATWG HTML standard's `text/event-stream`) as its bytes arrive, in
/// chunks that may end anywhere, even inside a line or a character. Lines end with LF, CRLF or CR; a blank line ends
/// a message, and a message without data is dropped.
public struct ServerSentEventParser {
    private var line: [UInt8] = []
    /// A chunk ended on CR: an LF that starts the next one belongs to the same line end.
    private var afterCR = false
    private var event = ""
    private var data: [String] = []
    private var lastID: String?

    public init() {}

    /// Every item of a whole stream.
    public static func parse(_ text: String) -> [ServerSentEventItem] {
        var parser = ServerSentEventParser()
        return parser.feed(Data(text.utf8))
    }

    /// The items the lines `chunk` completes.
    public mutating func feed(_ chunk: Data) -> [ServerSentEventItem] {
        var items: [ServerSentEventItem] = []
        for byte in chunk {
            if afterCR {
                afterCR = false
                if byte == 0x0A { continue }
            }
            switch byte {
            case 0x0A:
                endLine(into: &items)
            case 0x0D:
                afterCR = true
                endLine(into: &items)
            default:
                line.append(byte)
            }
        }
        return items
    }

    private mutating func endLine(into items: inout [ServerSentEventItem]) {
        let text = String(decoding: line, as: UTF8.self)
        line.removeAll(keepingCapacity: true)
        if text.isEmpty {
            dispatch(into: &items)
        } else if text.hasPrefix(":") {
            items.append(.comment(Self.value(text.dropFirst())))
        } else if let colon = text.firstIndex(of: ":") {
            field(String(text[..<colon]), Self.value(text[text.index(after: colon)...]))
        } else {
            field(text, "")
        }
    }

    private mutating func field(_ name: String, _ value: String) {
        switch name {
        case "event": event = value
        case "data": data.append(value)
        case "id" where !value.contains("\u{0}"): lastID = value
        default: break
        }
    }

    private mutating func dispatch(into items: inout [ServerSentEventItem]) {
        defer {
            event = ""
            data = []
        }
        guard !data.isEmpty else { return }
        items.append(.event(ServerSentEvent(event: event.isEmpty ? "message" : event, data: data.joined(separator: "\n"), id: lastID)))
    }

    /// A field's value: what follows its colon, without one leading space.
    private static func value(_ text: Substring) -> String {
        String(text.hasPrefix(" ") ? text.dropFirst() : text)
    }
}

/// Symphony's notice that an event was written to a ticket's history (`event: ticket` on `/api/v1/stream`).
public struct EventStreamNotice: Decodable, Equatable {
    public var repoKey: String?
    public var issueId: String
    public var issueIdentifier: String?
    public var eventId: String
    public var type: String
    public var at: String?

    public init(repoKey: String?, issueId: String, issueIdentifier: String?, eventId: String, type: String, at: String?) {
        self.repoKey = repoKey
        self.issueId = issueId
        self.issueIdentifier = issueIdentifier
        self.eventId = eventId
        self.type = type
        self.at = at
    }

    public static func decode(_ data: String) -> EventStreamNotice? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(EventStreamNotice.self, from: Data(data.utf8))
    }
}

/// Where the live channel stands.
public enum EventStreamState: Equatable {
    /// Not opened, or closed by `stop()`.
    case stopped
    case connecting
    case connected
    /// The connection dropped or couldn't be made; it is tried again after `after` seconds.
    case reconnecting(after: TimeInterval)
    /// Symphony has no channel (an older Symphony answers 404): the window keeps polling, and the channel is tried
    /// again only when the window connects to Symphony again.
    case unavailable
}

/// The live channel to Symphony (`GET /api/v1/stream`): Symphony tells the app the moment an event is written to a
/// ticket's history, and the stream publishes each notice. A dropped connection is opened again after 1 second, then
/// 2, 4… up to 30 seconds between tries, back to 1 once Symphony answers.
@MainActor
public final class EventStream: ObservableObject {
    public static let path = "api/v1/stream"
    public static let firstDelay: TimeInterval = 1
    public static let maxDelay: TimeInterval = 30
    /// Symphony sends a keep-alive line every 15 s: a connection silent for three of them is dead.
    public static let idleTimeout: TimeInterval = 45

    /// What opening the channel got: the status code, and the body as it arrives.
    public struct Response {
        public var statusCode: Int
        public var body: AsyncThrowingStream<Data, Error>

        public init(statusCode: Int, body: AsyncThrowingStream<Data, Error>) {
            self.statusCode = statusCode
            self.body = body
        }
    }

    /// Opens a request and returns its response as soon as its headers arrive.
    public typealias Connect = (URLRequest) async throws -> Response

    @Published public private(set) var state: EventStreamState = .stopped
    /// The last notice Symphony sent.
    @Published public private(set) var lastNotice: EventStreamNotice?
    /// Every notice Symphony sends, as it arrives.
    public let notices = PassthroughSubject<EventStreamNotice, Never>()

    private let base: () -> URL?
    private let connect: Connect
    private let scheduler: PollScheduler
    private(set) var task: Task<Void, Never>?
    private var timer: PollTimer?
    /// Tries since Symphony last answered.
    private var failures = 0
    /// Bumped by `stop()`, so a connection it ended changes nothing.
    private var generation = 0

    public init(base: @escaping () -> URL?, connect: @escaping Connect, scheduler: PollScheduler = RunLoopScheduler()) {
        self.base = base
        self.connect = connect
        self.scheduler = scheduler
    }

    /// The wait before the next try, after `failures` tries in a row.
    nonisolated public static func delay(afterFailures failures: Int) -> TimeInterval {
        min(firstDelay * pow(2, Double(min(failures, 5))), maxDelay)
    }

    /// Opens the channel; a no-op unless it is stopped.
    public func start() {
        guard state == .stopped else { return }
        failures = 0
        open()
    }

    /// Closes the channel until the next `start()`.
    public func stop() {
        generation += 1
        task?.cancel()
        task = nil
        timer?.cancel()
        timer = nil
        state = .stopped
    }

    private func open() {
        timer = nil
        guard let base = base(), let url = LiveAPIClient.url(Self.path, base: base) else { return retry() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Self.idleTimeout)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        state = .connecting
        let generation = generation
        task = Task { await self.run(request, generation: generation) }
    }

    private func run(_ request: URLRequest, generation: Int) async {
        let response = try? await connect(request)
        guard generation == self.generation else { return }
        if response?.statusCode == 404 {
            task = nil
            state = .unavailable
            return
        }
        if let response, response.statusCode == 200 {
            state = .connected
            failures = 0
            await read(response.body, generation: generation)
            guard generation == self.generation else { return }
        }
        task = nil
        retry()
    }

    private func read(_ body: AsyncThrowingStream<Data, Error>, generation: Int) async {
        var parser = ServerSentEventParser()
        do {
            for try await chunk in body {
                guard generation == self.generation else { return }
                parser.feed(chunk).forEach(handle)
            }
        } catch {}
    }

    private func handle(_ item: ServerSentEventItem) {
        guard case let .event(event) = item, event.event == "ticket", let notice = EventStreamNotice.decode(event.data) else { return }
        lastNotice = notice
        notices.send(notice)
    }

    private func retry() {
        let delay = Self.delay(afterFailures: failures)
        failures += 1
        state = .reconnecting(after: delay)
        timer = scheduler.schedule(after: delay) { [weak self] in self?.open() }
    }
}

extension EventStream {
    /// Streams the response body from `session` as it arrives, a line at a time.
    nonisolated public static func streaming(session: URLSession = .shared) -> Connect {
        { request in
            let (bytes, response) = try await session.bytes(for: request)
            let body = AsyncThrowingStream<Data, Error> { continuation in
                let reader = Task {
                    do {
                        var line = Data()
                        for try await byte in bytes {
                            line.append(byte)
                            guard byte == 0x0A else { continue }
                            continuation.yield(line)
                            line.removeAll(keepingCapacity: true)
                        }
                        if !line.isEmpty { continuation.yield(line) }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in reader.cancel() }
            }
            return Response(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0, body: body)
        }
    }

    /// Opens the channel through a transport that answers whole bodies, such as the API fixtures': the body arrives
    /// at once and the stream ends after it.
    nonisolated public static func buffered(_ transport: @escaping ControlAPI.Transport) -> Connect {
        { request in
            let (data, response) = try await transport(request)
            let body = AsyncThrowingStream<Data, Error> { continuation in
                continuation.yield(data)
                continuation.finish()
            }
            return Response(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0, body: body)
        }
    }
}
