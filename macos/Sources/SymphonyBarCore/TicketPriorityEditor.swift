import Foundation

/// The ticket page's Priority card (TP-1355): the shown ticket's Linear priority, as Symphony's record holds it
/// (`GET /api/v1/tickets/:identifier/priority`), and a menu of Linear's five priorities to change it. A pick sends
/// `POST /api/v1/control/priority`; Symphony writes it to Linear, and the dispatch reads it at once, so a ticket set
/// out of `tickets.priorities` is no longer picked for a run. A refusal keeps the shown priority and says why under it.
@MainActor
public final class TicketPriorityEditor: ObservableObject {
    /// What the card knows of the ticket's priority.
    public enum Load: Equatable {
        /// Not read yet.
        case unread
        case loaded
        /// Symphony didn't answer it: it doesn't track the ticket, or it predates the move.
        case unavailable
    }

    public static let title = "Priority"
    public static let readingReason = "Reading the ticket's priority…"
    public static let unavailableReason = "Symphony doesn't show a priority for this ticket: it doesn't track it, or this version of Symphony can't."
    public static let sendingTitle = "Saving the priority…"

    /// The ticket whose card this is.
    public private(set) var identifier: String?
    /// The ticket's priority, nil until read.
    @Published public private(set) var priority: TicketPriority?
    @Published public private(set) var load: Load
    /// True while a change is on its way; another meanwhile sends nothing.
    @Published public private(set) var sending = false
    /// Why the last change wasn't made: Symphony's answer.
    @Published public private(set) var refusal: String?

    /// An empty card; or, for an offscreen render or a test, ticket `identifier`'s card as given.
    public init(identifier: String? = nil, priority: TicketPriority? = nil, load: Load = .unread, refusal: String? = nil) {
        self.identifier = identifier
        self.priority = priority
        self.load = load
        self.refusal = refusal
    }

    /// The priorities the menu offers, in Linear's order.
    public static let choices = TicketPriority.allCases

    /// The ticket's priority endpoint.
    public static func path(_ identifier: String) -> String {
        let segment = identifier.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#")))
        return "api/v1/tickets/\(segment ?? identifier)/priority"
    }

    /// "Priority of TP-1: Urgent", the menu's label for VoiceOver.
    public static func menuLabel(_ identifier: String, _ priority: TicketPriority?) -> String {
        "Priority of \(identifier): \(priority?.title ?? "unknown")"
    }

    /// "Priority not saved: …", the refusal line for VoiceOver.
    public static func refusalLabel(_ reason: String) -> String { "Priority not saved: \(reason)" }

    /// Shows the card of ticket `identifier`: another ticket's starts unread.
    public func show(_ identifier: String?) {
        guard identifier != self.identifier else { return }
        self.identifier = identifier
        priority = nil
        load = .unread
        refusal = nil
        sending = false
    }

    /// Takes the priority endpoint's body for ticket `identifier`; nil (no answer, a 404) or a body that doesn't read
    /// makes the card unavailable. An answer for a ticket no longer shown changes nothing.
    public func apply(_ data: Data?, for identifier: String) {
        guard identifier == self.identifier else { return }
        guard let data, let payload = try? JSONDecoder().decode(Payload.self, from: data),
              let priority = TicketPriority(rawValue: payload.priority) else {
            priority = nil
            load = .unavailable
            return
        }
        self.priority = priority
        load = .loaded
    }

    /// Whether picking `priority` would send: the card is read, it is another priority and nothing is on its way.
    public func canSet(_ priority: TicketPriority) -> Bool { load == .loaded && !sending && priority != self.priority }

    /// A pick from the menu: sets the shown ticket's priority with `send`, then `read`s the card again. Returns whether
    /// Symphony made the change.
    @discardableResult
    public func set(_ priority: TicketPriority, send: (ControlAction) async -> ControlResult, read: (String) async -> Data?) async -> Bool {
        guard let identifier, canSet(priority) else { return false }
        sending = true
        refusal = nil
        let result = await send(.priority(identifier, priority: priority))
        // The page moved to another ticket meanwhile: this card is another one.
        guard self.identifier == identifier else {
            if case .failed = result { return false }
            return true
        }
        sending = false
        if case let .failed(message) = result {
            refusal = message
            return false
        }
        // Shown at once; the read that follows confirms it from Symphony's record.
        self.priority = priority
        apply(await read(Self.path(identifier)), for: identifier)
        return true
    }

    private struct Payload: Decodable {
        let priority: String
    }
}
