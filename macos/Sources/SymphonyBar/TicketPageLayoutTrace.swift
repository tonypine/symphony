import Foundation
import SymphonyBarCore

/// A diagnostic for TP-1466, QA mode only: once a second, while the ticket page measures itself, one line in
/// `<QA root>/ticket-page-layout.jsonl` counting the measurements the page reported in that second and how many of
/// them changed a value (and so re-rendered the page). A page that settles writes nothing after it opens; a page
/// stuck re-measuring itself writes a line every second. Outside QA mode it does nothing. Called on the main thread,
/// from the page's geometry callbacks.
enum TicketPageLayoutTrace {
    private static let file: URL? = QAMode.detect(environment: ProcessInfo.processInfo.environment)
        .map { $0.root.appendingPathComponent("ticket-page-layout.jsonl") }
    private static var windowStart = Date()
    private static var measured = 0
    private static var published = 0

    /// Counts one measurement the page reported, `changed` when it changed a published value.
    static func record(_ kind: String, changed: Bool) {
        guard let file else { return }
        measured += 1
        if changed { published += 1 }
        let now = Date()
        guard now.timeIntervalSince(windowStart) >= 1 else { return }
        let line = "{\"at\":\"\(ISO8601DateFormatter().string(from: now))\",\"last\":\"\(kind)\","
            + "\"measured\":\(measured),\"published\":\(published)}\n"
        windowStart = now
        measured = 0
        published = 0
        append(line, to: file)
    }

    private static func append(_ line: String, to file: URL) {
        let data = Data(line.utf8)
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: file)
        }
    }
}
