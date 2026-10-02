import Foundation

/// What the menu shows from one `GET /api/v1/state` response.
public struct StateSnapshot: Equatable {
    public var running: Int
    public var retrying: Int
    /// Set while dispatch is paused, nil otherwise.
    public var pause: Pause?

    public struct Pause: Equatable {
        public var reason: String?
        public var since: Date?

        public init(reason: String? = nil, since: Date? = nil) {
            self.reason = reason
            self.since = since
        }
    }

    public init(running: Int = 0, retrying: Int = 0, pause: Pause? = nil) {
        self.running = running
        self.retrying = retrying
        self.pause = pause
    }
}

/// The outcome of polling Symphony's state.
public enum StatusPoll: Equatable {
    /// Symphony answered with its state.
    case state(StateSnapshot)
    /// Nothing answered on the control URL.
    case unreachable
    /// Something answered, but not with a state; the message says what went wrong.
    case failed(String)
}

/// Reads what the app needs from Symphony's `GET /api/v1/state`.
public enum SymphonyState {
    /// Dashboard URL used when Symphony hasn't written its control URL file.
    public static let defaultBaseURL = URL(string: "http://127.0.0.1:4000")!

    /// The file Symphony writes its control-plane URL to on start.
    public static func controlURLFile(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Application Support/symphony/control_url")
    }

    /// The URL in the control URL file's contents, or the default when they are empty or not a URL.
    public static func baseURL(controlURLContents: String?) -> URL {
        let text = controlURLContents?.trimmingWhitespace() ?? ""
        guard let url = URL(string: text), let scheme = url.scheme, ["http", "https"].contains(scheme),
            url.host != nil
        else { return defaultBaseURL }
        return url
    }

    /// The URL in the control URL file, or the default when the file is missing or holds no URL.
    public static func baseURL(controlURLFile file: URL) -> URL {
        baseURL(controlURLContents: try? String(contentsOf: file, encoding: .utf8))
    }

    public static func stateURL(base: URL) -> URL {
        base.appendingPathComponent("api/v1/state")
    }

    /// Turns a state response into a poll result.
    public static func poll(data: Data, statusCode: Int) -> StatusPoll {
        guard statusCode == 200 else { return .failed("Symphony answered with HTTP \(statusCode)") }
        guard let payload = try? decoder.decode(Payload.self, from: data) else {
            return .failed("Symphony's state couldn't be read")
        }
        if let error = payload.error {
            return .failed(error.message ?? error.code ?? "Symphony reported an error")
        }
        guard let counts = payload.counts else { return .failed("Symphony's state couldn't be read") }

        var snapshot = StateSnapshot(running: counts.running, retrying: counts.retrying ?? 0)
        if let pause = payload.pause, pause.paused {
            snapshot.pause = .init(reason: pause.reason, since: pause.pausedAt.flatMap(parseDate))
        }
        return .state(snapshot)
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    /// Symphony writes whole-second UTC timestamps, for example `2026-10-02T12:16:02Z`.
    private static func parseDate(_ text: String) -> Date? {
        ISO8601DateFormatter().date(from: text)
    }

    private struct Payload: Decodable {
        struct Counts: Decodable {
            let running: Int
            let retrying: Int?
        }

        struct Pause: Decodable {
            let paused: Bool
            let reason: String?
            let pausedAt: String?
        }

        struct Failure: Decodable {
            let code: String?
            let message: String?
        }

        let counts: Counts?
        let pause: Pause?
        let error: Failure?
    }
}
