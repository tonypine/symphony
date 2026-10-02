import Foundation

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

    public static func stateURL(base: URL) -> URL {
        base.appendingPathComponent("api/v1/state")
    }

    /// `counts.running` from a state response, or nil when the body isn't a state payload.
    public static func runningCount(fromStateJSON data: Data) -> Int? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let counts = object["counts"] as? [String: Any]
        else { return nil }
        return counts["running"] as? Int
    }
}
