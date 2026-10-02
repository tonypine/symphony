import Foundation

/// The log file Symphony's stdout and stderr go to. Each start keeps the previous run as `.1`.
public enum ChildLog {
    public static let fileName = "menubar-child.log"

    /// `~/Library/Logs/symphony`, next to Symphony's own logs.
    public static func defaultDirectory(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Logs/symphony", isDirectory: true)
    }

    /// Moves the current log to `<name>.1` (replacing the older one), creates an empty log and returns its URL.
    @discardableResult
    public static func rotate(in directory: URL, fileManager: FileManager = .default) throws -> URL {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let log = directory.appendingPathComponent(fileName)
        let previous = directory.appendingPathComponent(fileName + ".1")
        if fileManager.fileExists(atPath: log.path) {
            if fileManager.fileExists(atPath: previous.path) {
                try fileManager.removeItem(at: previous)
            }
            try fileManager.moveItem(at: log, to: previous)
        }
        let descriptor = open(log.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        close(descriptor)
        return log
    }
}
