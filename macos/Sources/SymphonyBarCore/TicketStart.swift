import Foundation

/// Start now (TP-1330): whether Symphony would start the ticket's run at once, ahead of the dispatch queue, as the
/// ticket payload and each ticket entry of the state payload say (`start: {allowed, reason}`, TP-1329). The button is
/// never clickable into a refusal: when `allowed` is false it is disabled and its tooltip is the reason. A Symphony
/// that predates Start now sends no `start`, and the app offers no button.
public struct TicketStart: Equatable, Decodable {
    public static let title = "Start Now"
    /// The button's title while the start is on its way to Symphony.
    public static let startingTitle = "Starting…"

    public var allowed: Bool
    /// Why it may not start, in Symphony's words ("dispatch is paused by the operator", "a run is already working on
    /// the ticket"); nil when it may.
    public var reason: String?

    public init(allowed: Bool, reason: String? = nil) {
        self.allowed = allowed
        self.reason = reason
    }

    private enum CodingKeys: String, CodingKey { case allowed, reason }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        allowed = try container.decode(Bool.self, forKey: .allowed)
        let reason = try container.decodeIfPresent(String.self, forKey: .reason)?.trimmingWhitespace()
        self.reason = reason?.isEmpty == false ? reason : nil
    }

    /// The button's tooltip: what it does, or why it can't, in Symphony's words with a capital first letter.
    public func help(_ identifier: String) -> String {
        if allowed { return "Start \(identifier)'s run now, ahead of the queue; the other tickets keep their order" }
        guard let reason else { return "Symphony won't start \(identifier) now" }
        return reason.prefix(1).uppercased() + reason.dropFirst()
    }

    /// What VoiceOver says for the button.
    public func accessibilityLabel(_ identifier: String) -> String {
        allowed ? "Start \(identifier) now" : "Start \(identifier) now, unavailable: \(help(identifier))"
    }

    /// The request the button sends.
    public static func action(_ identifier: String) -> ControlAction { .start(identifier, note: nil) }

    /// The ticket's `start`, from its own payload, else from its entry in the state; nil when neither says.
    public static func of(_ identifier: String, issue: Data?, state: Data?) -> TicketStart? {
        struct Carrier: Decodable {
            let start: TicketStart?
        }
        if let issue, let start = (try? JSONDecoder().decode(Carrier.self, from: issue))?.start { return start }
        return byIdentifier(inState: state)[identifier]
    }

    /// Each ticket's `start` as the state payload's lists carry it, by identifier; empty from a Symphony that sends
    /// none. A ticket listed twice takes its first entry, in the order the lists are read.
    public static func byIdentifier(inState data: Data?) -> [String: TicketStart] {
        struct Entry: Decodable {
            let issue_identifier: String?
            let start: TicketStart?

            private enum CodingKeys: String, CodingKey { case issue_identifier, start }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                issue_identifier = try? container.decodeIfPresent(String.self, forKey: .issue_identifier)
                start = try? container.decodeIfPresent(TicketStart.self, forKey: .start)
            }
        }
        struct Lists: Decodable {
            let running: [Entry]?
            let retrying: [Entry]?
            let watching: [Entry]?
            let slot_waiting: [Entry]?
            let dispatch_skipped: [Entry]?
        }
        guard let data, let lists = try? JSONDecoder().decode(Lists.self, from: data) else { return [:] }
        var starts: [String: TicketStart] = [:]
        for entry in [lists.running, lists.retrying, lists.watching, lists.slot_waiting, lists.dispatch_skipped]
            .compactMap({ $0 }).joined() {
            guard let identifier = entry.issue_identifier, let start = entry.start, starts[identifier] == nil else { continue }
            starts[identifier] = start
        }
        return starts
    }
}
