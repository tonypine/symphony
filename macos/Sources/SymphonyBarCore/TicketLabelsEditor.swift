import Foundation

/// One of the labels a person adds for Symphony to read, as a toggle on the ticket page (TP-1356): `label` is the
/// Linear label, `title` the toggle's name ("Skip QA"), `effect` the one line saying what it does.
public struct TicketLabelToggle: Equatable, Identifiable, Decodable {
    public let label: String
    public let title: String
    public let effect: String
    public var on: Bool

    public var id: String { label }

    public init(label: String, title: String, effect: String, on: Bool) {
        self.label = label
        self.title = title
        self.effect = effect
        self.on = on
    }
}

/// The ticket page's Labels card (TP-1356): the labels a person adds for Symphony to read (Plan, Bug, Feature, Skip
/// QA, …), each a toggle with its one-line effect, as Symphony's record holds them
/// (`GET /api/v1/tickets/:identifier/labels`). A toggle sends `POST /api/v1/control/label`; Symphony writes the label to
/// Linear and reads it at once. A refusal keeps the toggle as it was and says why under the card.
@MainActor
public final class TicketLabelsEditor: ObservableObject {
    /// What the card knows of the ticket's labels.
    public enum Load: Equatable {
        /// Not read yet.
        case unread
        case loaded
        /// Symphony didn't answer it: it doesn't track the ticket, or it predates the move.
        case unavailable
    }

    public static let title = "Labels"
    public static let readingReason = "Reading the ticket's labels…"
    public static let unavailableReason = "Symphony doesn't show labels for this ticket: it doesn't track it, or this version of Symphony can't."

    /// The ticket whose card this is.
    public private(set) var identifier: String?
    /// The ticket's toggles, in Symphony's order; empty until read.
    @Published public private(set) var toggles: [TicketLabelToggle]
    @Published public private(set) var load: Load
    /// The label whose change is on its way; another meanwhile sends nothing.
    @Published public private(set) var sending: String?
    /// Why the last change wasn't made: Symphony's answer.
    @Published public private(set) var refusal: String?

    /// An empty card; or, for an offscreen render or a test, ticket `identifier`'s card as given.
    public init(identifier: String? = nil, toggles: [TicketLabelToggle] = [], load: Load = .unread, refusal: String? = nil) {
        self.identifier = identifier
        self.toggles = toggles
        self.load = load
        self.refusal = refusal
    }

    /// The ticket's labels endpoint.
    public static func path(_ identifier: String) -> String {
        let segment = identifier.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#")))
        return "api/v1/tickets/\(segment ?? identifier)/labels"
    }

    /// "Skip QA on SHOP-1: Once approved, it goes on without a QA pass", the toggle's label for VoiceOver.
    public static func toggleLabel(_ identifier: String, _ toggle: TicketLabelToggle) -> String {
        "\(toggle.title) on \(identifier): \(toggle.effect)"
    }

    /// "Label not saved: …", the refusal line for VoiceOver.
    public static func refusalLabel(_ reason: String) -> String { "Label not saved: \(reason)" }

    /// "Turning on Skip QA…", the line while a change is on its way.
    public static func sendingTitle(_ toggle: TicketLabelToggle) -> String {
        "Turning \(toggle.on ? "off" : "on") \(toggle.title)…"
    }

    /// Shows the card of ticket `identifier`: another ticket's starts unread.
    public func show(_ identifier: String?) {
        guard identifier != self.identifier else { return }
        self.identifier = identifier
        toggles = []
        load = .unread
        refusal = nil
        sending = nil
    }

    /// Takes the labels endpoint's body for ticket `identifier`; nil (no answer, a 404) or a body that doesn't read
    /// makes the card unavailable. An answer for a ticket no longer shown changes nothing.
    public func apply(_ data: Data?, for identifier: String) {
        guard identifier == self.identifier else { return }
        guard let data, let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            toggles = []
            load = .unavailable
            return
        }
        toggles = payload.labels
        load = .loaded
    }

    /// Whether `label`'s toggle would send: the card is read, it is one of its toggles and nothing is on its way.
    public func canToggle(_ label: String) -> Bool {
        load == .loaded && sending == nil && toggles.contains { $0.label == label }
    }

    /// A toggle flipped to `on`: changes the shown ticket's label with `send`, then `read`s the card again. Returns
    /// whether Symphony made the change.
    @discardableResult
    public func set(_ label: String, on: Bool, send: (ControlAction) async -> ControlResult, read: (String) async -> Data?) async -> Bool {
        guard let identifier, canToggle(label), let index = toggles.firstIndex(where: { $0.label == label }), toggles[index].on != on else {
            return false
        }
        let toggle = toggles[index]
        sending = label
        refusal = nil
        let result = await send(.label(identifier, label: label, title: toggle.title, on: on))
        // The page moved to another ticket meanwhile: this card is another one.
        guard self.identifier == identifier else {
            if case .failed = result { return false }
            return true
        }
        sending = nil
        if case let .failed(message) = result {
            refusal = message
            return false
        }
        // Shown at once; the read that follows confirms it from Symphony's record.
        if let shown = toggles.firstIndex(where: { $0.label == label }) { toggles[shown].on = on }
        apply(await read(Self.path(identifier)), for: identifier)
        return true
    }

    private struct Payload: Decodable {
        let labels: [TicketLabelToggle]
    }
}
