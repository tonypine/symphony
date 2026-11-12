import Foundation

/// Symphony's local API served from files, for QA mode with `SYMPHONY_BAR_QA_API_FIXTURES=<dir>`: each GET reads
/// `<dir>/<path>.json` (for example `api/v1/state.json`); without one it answers `<path>.png` or `<path>.jpg` with its
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
/// webhook secret Symphony hands off (`WebhookSecret`), a made-up value. No request leaves the app, so QA walks every
/// view with fixed data and no Linear or model calls.
public struct APIFixtures: Equatable {
    /// The base URL requests are built on while fixtures answer. Never contacted: the transport answers by path.
    public static let baseURL = URL(string: "http://symphony-fixtures.invalid")!
    /// The control token control requests carry while fixtures answer.
    public static let token = "qa-fixtures"
    /// The request log's file name, under the QA root.
    public static let requestLogFileName = "api-requests.jsonl"

    public let directory: URL
    public let requestLog: URL

    public init(directory: URL, requestLog: URL) {
        self.directory = directory.standardizedFileURL
        self.requestLog = requestLog
    }

    /// The fixture file for a request path such as `/api/v1/state`, nil for a path that would leave the directory.
    public func file(forPath path: String) -> URL? {
        let parts = path.split(separator: "/").map(String.init)
        guard !parts.isEmpty, !parts.contains(where: { $0 == ".." || $0 == "." }) else { return nil }
        return directory.appendingPathComponent(parts.joined(separator: "/") + ".json")
    }

    /// Answers `request` from the fixtures: a GET with its file, a POST by logging it.
    public func answer(_ request: URLRequest, now: Date = Date()) -> (Data, HTTPURLResponse) {
        let url = request.url ?? Self.baseURL
        let file = file(forPath: url.path)
        let method = request.httpMethod?.uppercased() ?? "GET"
        let isPost = method == "POST" || method == "DELETE"
        let fixture = (isPost ? nil : file.flatMap(afterFixture(of:))) ?? file.flatMap { try? Data(contentsOf: $0) }
        if isPost {
            let answer = fixture ?? file.flatMap { sequenceFile(of: $0, request: postCount(url.path) + 1) }.flatMap { try? Data(contentsOf: $0) }
            log(request, method: method, path: url.path, at: now)
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

    /// A transport for `ControlAPI`, `ReposAPI` and the window's client that answers from the fixtures.
    public var transport: ControlAPI.Transport {
        { request in
            let (data, response) = answer(request)
            return (data, response)
        }
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

    /// Appends `{"at", "method", "path", "body"}` to the request log, creating it if needed.
    private func log(_ request: URLRequest, method: String, path: String, at date: Date) {
        var entry: [String: Any] = [
            "at": ISO8601DateFormatter().string(from: date),
            "method": method,
            "path": path,
        ]
        if let body = request.httpBody, let json = try? JSONSerialization.jsonObject(with: body) {
            entry["body"] = json
        }
        guard var line = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys, .withoutEscapingSlashes]) else { return }
        line.append(0x0A)
        let manager = FileManager.default
        try? manager.createDirectory(at: requestLog.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !manager.fileExists(atPath: requestLog.path) {
            manager.createFile(atPath: requestLog.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: requestLog) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line)
    }
}
