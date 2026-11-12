import Foundation

/// One decision recorded on a ticket, as its Decisions card lists it (TP-1357): `id` is its label in the ticket's
/// Decisions section ("D2"), `answer` what was decided, and `question` what it answered (a ruling the Director recorded
/// unprompted says no question was asked).
public struct TicketDecision: Equatable, Identifiable, Decodable {
    public let id: String
    public let date: String?
    public let title: String?
    public let question: String?
    public let answer: String
    public let scope: String?

    public init(id: String, date: String? = nil, title: String? = nil, question: String? = nil, answer: String, scope: String? = nil) {
        self.id = id
        self.date = date
        self.title = title
        self.question = question
        self.answer = answer
        self.scope = scope
    }
}

/// The ticket page's Decisions card (TP-1357): the decisions recorded on the ticket, a Decide answer or a ruling, as
/// Symphony's record holds them (`GET /api/v1/tickets/:identifier/decisions`), and the "Record a decision" field. Record
/// sends `POST /api/v1/control/decision`: Symphony writes the ruling into the ticket's Decisions (in Linear too), and
/// every later run follows it. On success the field clears and the card reads again; a refusal keeps the text and says
/// why under the field.
@MainActor
public final class TicketDecisionsEditor: ObservableObject {
    /// What the card knows of the ticket's decisions.
    public enum Load: Equatable {
        /// Not read yet.
        case unread
        case loaded
        /// Symphony didn't answer it: it doesn't track the ticket, or it predates the card.
        case unavailable
    }

    /// The most characters a decision holds: a decision's answer bound, which Symphony checks too.
    public static let maxLength = 600
    public static let title = "Decisions"
    public static let buttonTitle = "Record a decision"
    public static let placeholder = "Record a decision"
    public static let hint = "Every later run, review and QA pass follows it, as if you had answered a question."
    public static let emptyReason = "No decisions recorded on this ticket yet."
    public static let sendingTitle = "Recording the decision…"
    public static let readingReason = "Reading the ticket's decisions…"
    public static let unavailableReason = "Symphony doesn't show decisions for this ticket: it doesn't track it, or this version of Symphony can't."

    /// The ticket whose card this is.
    public private(set) var identifier: String?
    /// The ticket's decisions, in the order recorded; empty until read.
    @Published public private(set) var decisions: [TicketDecision]
    @Published public private(set) var load: Load
    /// The ruling being written.
    @Published public var text: String
    /// True while a ruling is on its way; another meanwhile sends nothing.
    @Published public private(set) var sending = false
    /// Why the last ruling wasn't recorded: too long, or Symphony's answer.
    @Published public private(set) var refusal: String?

    /// An empty card; or, for an offscreen render or a test, ticket `identifier`'s card as given.
    public init(identifier: String? = nil, decisions: [TicketDecision] = [], load: Load = .unread, text: String = "", refusal: String? = nil) {
        self.identifier = identifier
        self.decisions = decisions
        self.load = load
        self.text = text
        self.refusal = refusal
    }

    /// The ticket's decisions endpoint.
    public static func path(_ identifier: String) -> String {
        let segment = identifier.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#")))
        return "api/v1/tickets/\(segment ?? identifier)/decisions"
    }

    /// "Decision on SHOP-1", the field's label for VoiceOver.
    public static func fieldLabel(_ identifier: String) -> String { "Decision on \(identifier)" }

    /// "Record a decision on SHOP-1", the button's label for VoiceOver.
    public static func buttonLabel(_ identifier: String) -> String { "Record a decision on \(identifier)" }

    /// "D1, 2026-11-03: Keep the old endpoint", a decision's row for VoiceOver.
    public static func rowLabel(_ decision: TicketDecision) -> String {
        "\(decision.id)\(decision.date.map { ", \($0)" } ?? ""): \(decision.answer)"
    }

    /// "Decision not recorded: …", the refusal line for VoiceOver.
    public static func refusalLabel(_ reason: String) -> String { "Decision not recorded: \(reason)" }

    /// Why `text` is too long to be a decision, nil when it isn't: the reason Symphony would give.
    public static func tooLong(_ text: String) -> String? {
        guard text.count > maxLength else { return nil }
        return "A decision holds at most \(maxLength) characters; this one has \(text.count)"
    }

    /// Shows the card of ticket `identifier`: another ticket's starts unread and empty.
    public func show(_ identifier: String?) {
        guard identifier != self.identifier else { return }
        self.identifier = identifier
        decisions = []
        load = .unread
        text = ""
        refusal = nil
        sending = false
    }

    /// Takes the decisions endpoint's body for ticket `identifier`; nil (no answer, a 404) or a body that doesn't read
    /// makes the card unavailable. An answer for a ticket no longer shown changes nothing.
    public func apply(_ data: Data?, for identifier: String) {
        guard identifier == self.identifier else { return }
        // The same answer read again publishes nothing (TP-1480).
        guard let data, let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            if !decisions.isEmpty { decisions = [] }
            if load != .unavailable { load = .unavailable }
            return
        }
        if decisions != payload.decisions { decisions = payload.decisions }
        if load != .loaded { load = .loaded }
    }

    /// Whether Record would send: the card is read, the text isn't blank and nothing is on its way.
    public var canRecord: Bool {
        load == .loaded && !sending && !text.trimmingWhitespace().isEmpty
    }

    /// Record: sends the ruling on the shown ticket with `send`, then `read`s the card again. A ruling over the bound
    /// is refused here, with the reason. Returns whether Symphony recorded it.
    @discardableResult
    public func record(send: (ControlAction) async -> ControlResult, read: (String) async -> Data?) async -> Bool {
        guard let identifier, canRecord else { return false }
        let ruling = text.trimmingWhitespace()
        if let reason = Self.tooLong(ruling) {
            refusal = reason
            return false
        }
        sending = true
        refusal = nil
        let result = await send(.decision(identifier, text: ruling))
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
        // What was typed while the ruling was on its way stays.
        if text.trimmingWhitespace() == ruling { text = "" }
        apply(await read(Self.path(identifier)), for: identifier)
        return true
    }

    private struct Payload: Decodable {
        let decisions: [TicketDecision]
    }
}
