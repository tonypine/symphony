import Foundation

/// Finds Symphony's state directory the way `SymphonyElixir.Paths` picks it, and reads the control plane's
/// URL and bearer token from it.
public enum StateRoot {
    /// Overrides the state directory, for Symphony and for the app.
    public static let environmentKey = "SYMPHONY_STATE_ROOT"

    /// Subdirectory the Burrito release build keeps its state in.
    public static let releaseSubdirectory = "release"

    public static let controlURLFileName = "control_url"
    public static let controlTokenFileName = "control_token"

    /// `~/Library/Application Support/symphony`, where `mix run` and the escript keep their state.
    public static func defaultDirectory(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Application Support/symphony", isDirectory: true)
    }

    /// The state directory: `SYMPHONY_STATE_ROOT` when set, else the default directory or its `release/`
    /// subdirectory. The app can't tell which build is running, so it picks the one whose control URL file
    /// was written last, then the one holding a control token, then the default directory.
    public static func locate(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let override = environment[environmentKey]?.trimmingWhitespace(), !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
                .standardizedFileURL
        }

        let base = defaultDirectory(home: home)
        let candidates = [base, base.appendingPathComponent(releaseSubdirectory, isDirectory: true)]

        let written = candidates.compactMap { root in
            modificationDate(root.appendingPathComponent(controlURLFileName)).map { (root, $0) }
        }
        if let newest = written.max(by: { $0.1 < $1.1 }) { return newest.0 }

        return candidates.first { modificationDate($0.appendingPathComponent(controlTokenFileName)) != nil } ?? base
    }

    /// The control plane URL in `root`, or `SymphonyState.defaultBaseURL` when Symphony hasn't written one.
    public static func controlURL(in root: URL) -> URL {
        SymphonyState.baseURL(controlURLFile: root.appendingPathComponent(controlURLFileName))
    }

    public static func controlTokenFile(in root: URL) -> URL {
        root.appendingPathComponent(controlTokenFileName)
    }

    /// The bearer token in `root`, or nil when the file is missing, unreadable or empty.
    public static func controlToken(in root: URL) -> String? {
        token(contents: try? String(contentsOf: controlTokenFile(in: root), encoding: .utf8))
    }

    /// The token in a control token file's contents, without the trailing newline Symphony writes.
    public static func token(contents: String?) -> String? {
        guard let token = contents?.trimmingWhitespace(), !token.isEmpty else { return nil }
        return token
    }

    private static func modificationDate(_ file: URL) -> Date? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
            attributes[.type] as? FileAttributeType == .typeRegular
        else { return nil }
        return attributes[.modificationDate] as? Date
    }
}
