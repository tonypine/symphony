import Foundation

/// The ticket page's Blocked by card (TP-1354): the tickets the shown ticket waits for, as Symphony's records hold them
/// (`GET /api/v1/tickets/:identifier/blockers`), each with Remove, and a field to add one: the Director types an
/// identifier or picks one of the open tickets Symphony tracks. Both send `POST /api/v1/control/blocker`; Symphony
/// writes the link to Linear and the ticket waits for its blocker at once. A refusal (a ticket blocking itself, a link
/// that would make a cycle, a ticket Symphony doesn't track) keeps the field as it was and says why under it.
@MainActor
public final class TicketBlockersEditor: ObservableObject {
    /// A blocker, or a ticket that can be one.
    public struct Ticket: Equatable, Identifiable {
        public var identifier: String
        public var title: String?
        /// Its phase, as Symphony's record says.
        public var state: String?
        public var id: String { identifier }

        public init(identifier: String, title: String? = nil, state: String? = nil) {
            self.identifier = identifier
            self.title = title
            self.state = state
        }

        /// "TP-12 Fix the exporter, In Progress", the row for VoiceOver.
        public var accessibilityLabel: String {
            ([identifier, title].compactMap { $0 }.joined(separator: " ") + (state.map { ", \($0)" } ?? ""))
        }
    }

    /// What the card knows of the ticket's blockers.
    public enum Load: Equatable {
        /// Not read yet.
        case unread
        case loaded
        /// Symphony didn't list them: it doesn't track the ticket, or it predates blockers.
        case unavailable
    }

    public static let title = "Blocked by"
    public static let empty = "Nothing blocks this ticket."
    public static let readingReason = "Reading the ticket's blockers…"
    public static let unavailableReason = "Symphony doesn't list blockers for this ticket: it doesn't track it, or this version of Symphony can't."
    public static let placeholder = "e.g. TP-12"
    public static let addTitle = "Add Blocker"
    public static let pickTitle = "Pick a Ticket"
    public static let removeTitle = "Remove"
    public static let sendingTitle = "Saving the blocker…"
    /// How many open tickets the Pick menu lists.
    public static let maxSuggestions = 12

    /// The ticket whose card this is.
    public private(set) var identifier: String?
    @Published public private(set) var blockers: [Ticket]
    /// The open tickets Symphony tracks that don't block it yet.
    @Published public private(set) var candidates: [Ticket]
    @Published public private(set) var load: Load
    /// The identifier typed in the add field.
    @Published public var entry: String
    /// True while a change is on its way; another meanwhile sends nothing.
    @Published public private(set) var sending = false
    /// Why the last change wasn't made: Symphony's answer.
    @Published public private(set) var refusal: String?

    /// An empty card; or, for an offscreen render or a test, ticket `identifier`'s card as given.
    public init(
        identifier: String? = nil, blockers: [Ticket] = [], candidates: [Ticket] = [], load: Load = .unread, entry: String = "",
        refusal: String? = nil
    ) {
        self.identifier = identifier
        self.blockers = blockers
        self.candidates = candidates
        self.load = load
        self.entry = entry
        self.refusal = refusal
    }

    /// The ticket's blockers endpoint.
    public static func path(_ identifier: String) -> String {
        let segment = identifier.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#")))
        return "api/v1/tickets/\(segment ?? identifier)/blockers"
    }

    /// "Remove TP-12 as a blocker", a row's Remove for VoiceOver.
    public static func removeLabel(_ blocker: String) -> String { "Remove \(blocker) as a blocker" }

    /// "Blocker of TP-1", the add field's label for VoiceOver.
    public static func fieldLabel(_ identifier: String) -> String { "Blocker of \(identifier)" }

    /// "Blocker not saved: …", the refusal line for VoiceOver.
    public static func refusalLabel(_ reason: String) -> String { "Blocker not saved: \(reason)" }

    /// Shows the card of ticket `identifier`: another ticket's starts unread and empty.
    public func show(_ identifier: String?) {
        guard identifier != self.identifier else { return }
        self.identifier = identifier
        blockers = []
        candidates = []
        load = .unread
        entry = ""
        refusal = nil
        sending = false
    }

    /// Takes the blockers endpoint's body for ticket `identifier`; nil (no answer, a 404) or a body that doesn't read
    /// makes the card unavailable. An answer for a ticket no longer shown changes nothing.
    public func apply(_ data: Data?, for identifier: String) {
        guard identifier == self.identifier else { return }
        guard let data, let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            blockers = []
            candidates = []
            load = .unavailable
            return
        }
        blockers = payload.blockers.compactMap(\.ticket)
        candidates = payload.candidates.compactMap(\.ticket)
        load = .loaded
    }

    /// The Pick menu: the open tickets whose identifier or title holds what is typed, all of them while nothing is.
    public var suggestions: [Ticket] {
        let typed = entry.trimmingWhitespace().lowercased()
        let matching = typed.isEmpty
            ? candidates
            : candidates.filter { $0.identifier.lowercased().contains(typed) || ($0.title?.lowercased().contains(typed) ?? false) }
        return Array(matching.prefix(Self.maxSuggestions))
    }

    /// Whether Add Blocker would send: the card is read, an identifier is typed and nothing is on its way.
    public var canAdd: Bool { load == .loaded && !sending && !entry.trimmingWhitespace().isEmpty }

    /// Add Blocker, or a pick from the menu (`blocker`): links it as a blocker of the shown ticket with `send`, then
    /// `read`s the card again. Returns whether Symphony made the change.
    @discardableResult
    public func add(
        _ blocker: String? = nil, send: (ControlAction) async -> ControlResult, read: (String) async -> Data?
    ) async -> Bool {
        let blocker = (blocker ?? entry).trimmingWhitespace()
        guard load == .loaded, !blocker.isEmpty else { return false }
        let made = await change(.blocker(identifier ?? "", blocker: blocker, add: true), send: send, read: read)
        if made, entry.trimmingWhitespace().caseInsensitiveCompare(blocker) == .orderedSame { entry = "" }
        return made
    }

    /// A row's Remove: unlinks `blocker` from the shown ticket with `send`, then `read`s the card again.
    @discardableResult
    public func remove(_ blocker: String, send: (ControlAction) async -> ControlResult, read: (String) async -> Data?) async -> Bool {
        guard load == .loaded else { return false }
        return await change(.blocker(identifier ?? "", blocker: blocker, add: false), send: send, read: read)
    }

    private func change(_ action: ControlAction, send: (ControlAction) async -> ControlResult, read: (String) async -> Data?) async -> Bool {
        guard let identifier, !sending else { return false }
        sending = true
        refusal = nil
        let result = await send(action)
        // The page moved to another ticket meanwhile: this card is another one.
        guard self.identifier == identifier else { return !isFailure(result) }
        sending = false
        if case let .failed(message) = result {
            refusal = message
            return false
        }
        apply(await read(Self.path(identifier)), for: identifier)
        return true
    }

    private func isFailure(_ result: ControlResult) -> Bool {
        if case .failed = result { return true }
        return false
    }

    private struct Payload: Decodable {
        struct Item: Decodable {
            let issue_identifier: String?
            let title: String?
            let state: String?

            var ticket: Ticket? { issue_identifier.map { Ticket(identifier: $0, title: title, state: state) } }
        }

        let blockers: [Item]
        let candidates: [Item]
    }
}
