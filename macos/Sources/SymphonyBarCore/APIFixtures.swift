import Foundation

/// Symphony's local API served from files, for QA mode with `SYMPHONY_BAR_QA_API_FIXTURES=<dir>`: each GET reads
/// `<dir>/<path>.json` (for example `api/v1/state.json`), or `<dir>/<path>.<query>.json` first for a GET with a query
/// (a filtered read); without one it answers `<path>.png` or `<path>.jpg` with its
/// image type (a screenshot's bytes), `<path>.txt` as plain text (a step's output), `<path>.410.json` with a 410 (a
/// file Symphony no longer keeps), and 404
/// when there is none of them (the live channel, so the app reads after each state poll); each POST is
/// appended to the request log as one JSON line and answered 200, with `<dir>/<path>.json` when there is one, or 409
/// with `<path>.409.json` when only that is there (Symphony refusing the move). A POST
/// whose answer changes from one request to the next reads `<path>.1.json` the first time, `<path>.2.json` the second,
/// and the last one there is after that (Setup's fix, Undo, fix again). A GET whose answer changes once a move was made
/// reads `<path>.after-<move>.json` once the request log holds a POST to `.../control/<move>` (a Question answered from
/// the ticket page: the Inbox, the ticket and its feed as Symphony serves them after `decide`), or
/// `<path>.after-<move>.<n>.json` after the `n`th such POST, when the same move changes it more than once (a view saved,
/// then renamed). A DELETE is a move like a POST: logged with its method, answered 200, and its last path component is
/// the move (`DELETE .../control/view/view-a1` reads `<path>.after-view-a1.json`). `<dir>/github_webhook_secret` stands for the
/// webhook secret Symphony hands off (`WebhookSecret`), a made-up value. `<dir>/api/v1/state.late.json`
/// (`{"after": 30, "for": 60}`) makes Symphony slow to give its state (TP-1562): a state read that arrives between
/// `after` and `after + for` seconds from the fixtures' first answer is held until that window ends, while every other
/// read answers at once, so QA sees the Director keep its pages and then answer again. No request leaves the app, so
/// QA walks every view with fixed data and no Linear or model calls. Each GET is logged too, to the read log beside
/// the request log (`api-reads.jsonl`) with its time, path, query and status, so QA can judge which reads the app
/// made; the moves' log stays the one the after-fixtures read.
public struct APIFixtures: Equatable {
    /// The base URL requests are built on while fixtures answer. Never contacted: the transport answers by path.
    public static let baseURL = URL(string: "http://symphony-fixtures.invalid")!
    /// The control token control requests carry while fixtures answer.
    public static let token = "qa-fixtures"
    /// The request log's file name, under the QA root.
    public static let requestLogFileName = "api-requests.jsonl"
    /// The read log's file name, beside the request log: the GETs, which change no fixture's answer.
    public static let readLogFileName = "api-reads.jsonl"
    /// When the fixtures first answered in this process: a late state's window counts from it.
    static let clockStart = Date()

    /// The window in which the state read is late, from `state.late.json` (TP-1562).
    public struct LateState: Decodable, Equatable {
        /// Seconds from the fixtures' first answer until the state read is late.
        public var after: TimeInterval
        /// Seconds the state read stays late.
        public var `for`: TimeInterval
    }

    public let directory: URL
    public let requestLog: URL

    public init(directory: URL, requestLog: URL) {
        self.directory = directory.standardizedFileURL
        self.requestLog = requestLog
    }

    /// The read log beside `requestLog`.
    public var readLog: URL { Self.readLog(beside: requestLog) }

    /// The read log beside a request log.
    public static func readLog(beside requestLog: URL) -> URL {
        requestLog.deletingLastPathComponent().appendingPathComponent(readLogFileName)
    }

    /// Whether `method` is a move (a POST or DELETE), logged to the request log; anything else is a read.
    static func isMove(_ method: String) -> Bool {
        method == "POST" || method == "DELETE"
    }

    /// The fixture file for a request path such as `/api/v1/state`, nil for a path that would leave the directory.
    public func file(forPath path: String) -> URL? {
        let parts = path.split(separator: "/").map(String.init)
        guard !parts.isEmpty, !parts.contains(where: { $0 == ".." || $0 == "." }) else { return nil }
        return directory.appendingPathComponent(parts.joined(separator: "/") + ".json")
    }

    /// Answers `request` from the fixtures: a GET with its file, a POST by logging it.
    public func answer(_ request: URLRequest, now: Date = Date()) -> (Data, HTTPURLResponse) {
        let (data, response) = answerUnlogged(request, now: now)
        if !Self.isMove(request.httpMethod?.uppercased() ?? "GET") {
            Self.logRead(request, statusCode: response.statusCode, at: now, to: readLog)
        }
        return (data, response)
    }

    private func answerUnlogged(_ request: URLRequest, now: Date) -> (Data, HTTPURLResponse) {
        let url = request.url ?? Self.baseURL
        let file = file(forPath: url.path)
        let method = request.httpMethod?.uppercased() ?? "GET"
        let isPost = Self.isMove(method)
        let fixture = (isPost ? nil : file.flatMap(afterFixture(of:)) ?? file.flatMap { queryFixture(of: $0, query: url.query) })
            ?? file.flatMap { try? Data(contentsOf: $0) }
        if isPost {
            let answer = fixture ?? file.flatMap { sequenceFile(of: $0, request: postCount(url.path) + 1) }.flatMap { try? Data(contentsOf: $0) }
            Self.logMove(request, method: method, path: url.path, at: now, to: requestLog)
            if answer == nil, let refusal = file.flatMap(refusalFixture(of:)) {
                return (refusal, response(url, statusCode: 409))
            }
            return (answer ?? Data(#"{"ok":true}"#.utf8), response(url, statusCode: 200))
        }
        guard let fixture else {
            if let file, let other = otherFixture(of: file) {
                return (other.data, response(url, statusCode: other.statusCode, contentType: other.contentType))
            }
            let body = #"{"error":{"code":"not_found","message":"No fixture for this path"}}"#
            return (Data(body.utf8), response(url, statusCode: 404))
        }
        return (fixture, response(url, statusCode: 200))
    }

    /// The GET answer `<path>.png`, `<path>.jpg`, `<path>.txt` or `<path>.410.json` gives next to `file` (`<path>.json`).
    func otherFixture(of file: URL) -> (data: Data, statusCode: Int, contentType: String)? {
        let stem = file.deletingPathExtension()
        let candidates = [
            (stem.appendingPathExtension("png"), 200, "image/png"),
            (stem.appendingPathExtension("jpg"), 200, "image/jpeg"),
            (stem.appendingPathExtension("txt"), 200, "text/plain; charset=utf-8"),
            (stem.appendingPathExtension("410").appendingPathExtension("json"), 410, "application/json"),
        ]
        for (url, statusCode, contentType) in candidates {
            if let data = try? Data(contentsOf: url) { return (data, statusCode, contentType) }
        }
        return nil
    }

    /// The GET answer `<path>.<query>.json` gives next to `file` (`<path>.json`) for a request with `query`, the query
    /// as the app wrote it (`api/v1/events.epic=TP-1381&limit=200&notable=true.json`): a read whose filters change its
    /// answer. Nil without a query, or a query that would leave the directory.
    func queryFixture(of file: URL, query: String?) -> Data? {
        guard let query, !query.isEmpty, !query.contains("/") else { return nil }
        let stem = file.deletingPathExtension()
        return try? Data(contentsOf: stem.deletingLastPathComponent().appendingPathComponent("\(stem.lastPathComponent).\(query).json"))
    }

    /// The GET answer `<path>.after-<move>.json` gives next to `file` (`<path>.json`) once the request log holds a POST
    /// whose path ends in `<move>`; the newest such POST wins.
    func afterFixture(of file: URL) -> Data? {
        let stem = file.deletingPathExtension()
        let moves = postedMoves()
        for (index, move) in moves.enumerated().reversed() {
            let after = stem.appendingPathExtension("after-\(move)")
            let number = moves[...index].filter { $0 == move }.count
            if let data = try? Data(contentsOf: after.appendingPathExtension("\(number)").appendingPathExtension("json")) { return data }
            if let data = try? Data(contentsOf: after.appendingPathExtension("json")) { return data }
        }
        return nil
    }

    /// The last path component of each POST the request log holds that Symphony took, oldest first: a POST the
    /// fixtures refuse (only `<path>.409.json` there) changed nothing.
    func postedMoves() -> [String] {
        postedPaths().filter { !refuses($0) }.compactMap { $0.split(separator: "/").last.map(String.init) }
    }

    /// Whether a POST to `path` is answered with its refusal.
    private func refuses(_ path: String) -> Bool {
        guard let file = file(forPath: path) else { return false }
        return !FileManager.default.fileExists(atPath: file.path) && refusalFixture(of: file) != nil
    }

    /// The POST answer `<path>.409.json` gives next to `file` (`<path>.json`): Symphony's refusal of the move.
    func refusalFixture(of file: URL) -> Data? {
        try? Data(contentsOf: file.deletingPathExtension().appendingPathExtension("409").appendingPathExtension("json"))
    }

    /// A transport for `ControlAPI`, `ReposAPI` and the window's client that answers from the fixtures, holding a
    /// late state read until its window ends.
    public var transport: ControlAPI.Transport {
        let start = Self.clockStart
        return { request in
            let wait = hold(request, now: Date(), since: start)
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            let (data, response) = answer(request)
            return (data, response)
        }
    }

    /// The late state the fixtures give, nil without `api/v1/state.late.json`.
    public var lateState: LateState? {
        guard let file = file(forPath: SymphonyState.stateURL(base: Self.baseURL).path) else { return nil }
        let late = file.deletingPathExtension().appendingPathExtension("late").appendingPathExtension("json")
        return (try? Data(contentsOf: late)).flatMap { try? JSONDecoder().decode(LateState.self, from: $0) }
    }

    /// Seconds to hold `request` before it is answered: until the late state's window ends for a state read that
    /// arrives inside it, `start` seconds being the fixtures' first answer; 0 for every other read.
    public func hold(_ request: URLRequest, now: Date, since start: Date) -> TimeInterval {
        guard let late = lateState, (request.httpMethod?.uppercased() ?? "GET") == "GET",
            request.url?.path == SymphonyState.stateURL(base: Self.baseURL).path
        else { return 0 }
        let elapsed = now.timeIntervalSince(start)
        guard elapsed >= late.after, elapsed < late.after + late.for else { return 0 }
        return late.after + late.for - elapsed
    }

    /// `<path>.<number>.json` next to `file` (`<path>.json`), or the highest-numbered one there is below it; nil when
    /// there is none.
    func sequenceFile(of file: URL, request number: Int) -> URL? {
        let stem = file.deletingPathExtension()
        let manager = FileManager.default
        for candidate in stride(from: number, through: 1, by: -1) {
            let url = stem.appendingPathExtension("\(candidate)").appendingPathExtension("json")
            if manager.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    /// The POSTs to `path` the request log holds.
    func postCount(_ path: String) -> Int {
        postedPaths().filter { $0 == path }.count
    }

    /// The path of each POST the request log holds, oldest first.
    private func postedPaths() -> [String] {
        guard let text = try? String(contentsOf: requestLog, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            (try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])?["path"] as? String
        }
    }

    private func response(_ url: URL, statusCode: Int, contentType: String = "application/json") -> HTTPURLResponse {
        // HTTPURLResponse's initializer only fails for a malformed HTTP version.
        HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": contentType]
        )!
    }

    /// A transport that sends each request with `transport` and logs it as the fixtures do: a move to `requestLog`
    /// with its body, a read to the read log beside it with its status. For the live Symphony QA talks to, so a pass
    /// sees the same logs with either.
    public static func logging(_ transport: @escaping ControlAPI.Transport, requestLog: URL, now: @escaping () -> Date = Date.init) -> ControlAPI.Transport {
        { request in
            let method = request.httpMethod?.uppercased() ?? "GET"
            let path = request.url?.path ?? "/"
            if isMove(method) {
                logMove(request, method: method, path: path, at: now(), to: requestLog)
                return try await transport(request)
            }
            do {
                let (data, response) = try await transport(request)
                logRead(request, statusCode: (response as? HTTPURLResponse)?.statusCode, at: now(), to: readLog(beside: requestLog))
                return (data, response)
            } catch {
                logRead(request, statusCode: nil, at: now(), to: readLog(beside: requestLog))
                throw error
            }
        }
    }

    /// Appends `{"at", "method", "path", "body"}` to the request log, creating it if needed.
    static func logMove(_ request: URLRequest, method: String, path: String, at date: Date, to log: URL) {
        var entry: [String: Any] = [
            "at": ISO8601DateFormatter().string(from: date),
            "method": method,
            "path": path,
        ]
        if let body = request.httpBody, let json = try? JSONSerialization.jsonObject(with: body) {
            entry["body"] = json
        }
        append(entry, to: log)
    }

    /// Appends `{"at", "method", "path", "query", "status"}` to the read log, creating it if needed: no query without
    /// one, no status for a read that got no answer.
    static func logRead(_ request: URLRequest, statusCode: Int?, at date: Date, to log: URL) {
        var entry: [String: Any] = [
            "at": ISO8601DateFormatter().string(from: date),
            "method": request.httpMethod?.uppercased() ?? "GET",
            "path": request.url?.path ?? "/",
        ]
        if let query = request.url?.query, !query.isEmpty { entry["query"] = query }
        if let statusCode { entry["status"] = statusCode }
        append(entry, to: log)
    }

    private static func append(_ entry: [String: Any], to log: URL) {
        guard var line = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys, .withoutEscapingSlashes]) else { return }
        line.append(0x0A)
        let manager = FileManager.default
        try? manager.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !manager.fileExists(atPath: log.path) {
            manager.createFile(atPath: log.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: log) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line)
    }
}
