import Foundation

/// QA's request to open the status-bar menu on screen (`qa_open_status_menu`), so a QA pass can screenshot it. Pressing
/// the status item through Accessibility can't do it: the menu's tracking loop holds the press until the menu closes. So
/// QA writes the file `<QA root>/status-menu/open-<pid>` instead, and the app with that PID, in QA mode only, takes it
/// away and opens its menu as a click on the item would.
public struct QAStatusMenuRequest: Equatable {
    public static let folderName = "status-menu"

    /// The request file this app watches.
    public let file: URL

    /// The request of the app with `pid`; nil outside QA mode, where the app watches for no request.
    public init?(qaMode: QAMode?, pid: Int32 = ProcessInfo.processInfo.processIdentifier) {
        guard let qaMode else { return nil }
        file = qaMode.root
            .appendingPathComponent(Self.folderName, isDirectory: true)
            .appendingPathComponent(Self.fileName(pid: pid))
    }

    public static func fileName(pid: Int32) -> String { "open-\(pid)" }

    /// Whether QA asked to open the menu since the last call. Takes the request away, so each one opens the menu once.
    public func take() -> Bool {
        (try? FileManager.default.removeItem(at: file)) != nil
    }
}
