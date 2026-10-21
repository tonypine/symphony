import Foundation

/// Symphony's local API served from files, for QA mode with `SYMPHONY_BAR_QA_API_FIXTURES=<dir>`: each GET reads
/// `<dir>/<path>.json` (for example `api/v1/state.json`) and answers 404 when there is no such file; each POST is
/// appended to the request log as one JSON line and answered 200, with `<dir>/<path>.json` when there is one. A POST
/// whose answer changes from one request to the next reads `<path>.1.json` the first time, `<path>.2.json` the second,
/// and the last one there is after that (Setup's fix, Undo, fix again). `<dir>/github_webhook_secret` stands for the
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
        let fixture = file.flatMap { try? Data(contentsOf: $0) }
        if request.httpMethod?.uppercased() == "POST" {
            let answer = fixture ?? file.flatMap { sequenceFile(of: $0, request: postCount(url.path) + 1) }.flatMap { try? Data(contentsOf: $0) }
            log(request, path: url.path, at: now)
            return (answer ?? Data(#"{"ok":true}"#.utf8), response(url, statusCode: 200))
        }
        guard let fixture else {
            let body = #"{"error":{"code":"not_found","message":"No fixture for this path"}}"#
            return (Data(body.utf8), response(url, statusCode: 404))
        }
        return (fixture, response(url, statusCode: 200))
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
        guard let text = try? String(contentsOf: requestLog, encoding: .utf8) else { return 0 }
        return text.split(separator: "\n").filter { line in
            guard let entry = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return false }
            return entry["path"] as? String == path
        }.count
    }

    private func response(_ url: URL, statusCode: Int) -> HTTPURLResponse {
        // HTTPURLResponse's initializer only fails for a malformed HTTP version.
        HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
    }

    /// Appends `{"at", "method", "path", "body"}` to the request log, creating it if needed.
    private func log(_ request: URLRequest, path: String, at date: Date) {
        var entry: [String: Any] = [
            "at": ISO8601DateFormatter().string(from: date),
            "method": "POST",
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
