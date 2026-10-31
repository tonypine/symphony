import Foundation

/// The update log, `~/Library/Logs/symphony/update.log`: one timestamped line per step of an update or a rollback,
/// written by the app and by the update helper, whose output is appended to the same file. It is never deleted, so the
/// steps of the last updates can be read after the fact.
public struct UpdateLog {
    public static let fileName = "update.log"
    /// Above this size the log is moved to `update.log.1` before the next update writes to it.
    public static let maxBytes = 1_000_000

    public let url: URL
    /// Who writes the line, such as `build 774`; the helper writes `helper`.
    private let source: String

    public init(directory: URL, source: String) {
        url = directory.appendingPathComponent(Self.fileName)
        self.source = source
    }

    /// The log's path, with `~` for the home folder.
    public var path: String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }

    /// `2026-10-31T03:38:08Z [build 774] message`, as the helper writes its lines.
    public static func line(_ message: String, source: String, at date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return "\(formatter.string(from: date)) [\(source)] \(message)\n"
    }

    /// Appends one line. A log that can't be written changes nothing else.
    public func append(_ message: String, at date: Date = Date()) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        let data = Data(Self.line(message, source: source, at: date).utf8)
        _ = data.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
    }

    /// Moves a log over `maxBytes` to `update.log.1`, replacing an older one, so the log stays small.
    public func rotateIfLarge(maxBytes: Int = maxBytes) {
        let files = FileManager.default
        guard let size = (try? files.attributesOfItem(atPath: url.path))?[.size] as? Int, size > maxBytes else { return }
        let old = url.appendingPathExtension("1")
        try? files.removeItem(at: old)
        try? files.moveItem(at: url, to: old)
    }
}

/// How the update helper and the app it relaunches tell each other that it started, through files in the update cache
/// folder (see `update-helper.sh`).
public enum UpdateLaunch {
    /// Written by every launch of the app; the helper waits for it after relaunching an update.
    public static let launchedName = "launched"
    /// Written by the helper when the new app didn't start and it put the previous one back.
    public static let failedName = "launch-failed"
    /// How long the helper gives the relaunched app to start.
    public static let timeout = 30

    /// Records that this app runs, for the helper that relaunched it.
    public static func markLaunched(in directory: URL, build: Int) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? Data("\(build)\n".utf8).write(to: directory.appendingPathComponent(launchedName))
    }

    /// Removes what an earlier update left, before the helper starts.
    public static func clearFailure(in directory: URL) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(failedName))
    }

    /// True when the helper put this app back because the update's app didn't start; cleared, so a later launch
    /// doesn't act on it again.
    public static func takeFailure(in directory: URL) -> Bool {
        let file = directory.appendingPathComponent(failedName)
        guard FileManager.default.fileExists(atPath: file.path) else { return false }
        try? FileManager.default.removeItem(at: file)
        return true
    }

    /// The rollback's reason, for the menu line and the notification of the build put back.
    public static func failureReason(logPath: String) -> String {
        "the app didn't start within \(timeout) seconds of the update; see \(logPath)"
    }
}
