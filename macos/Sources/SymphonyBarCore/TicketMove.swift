import Foundation

/// A phase of Symphony's state machine as the state payload's `phases` lists them (TP-1333): its name as the
/// workflow names it, and whether entering it starts a run.
public struct MachinePhase: Equatable, Decodable, Identifiable {
    public var name: String
    public var dispatches: Bool

    public var id: String { name }

    public init(name: String, dispatches: Bool) {
        self.name = name
        self.dispatches = dispatches
    }

    private enum CodingKeys: String, CodingKey {
        case name, dispatches
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        dispatches = try container.decodeIfPresent(Bool.self, forKey: .dispatches) ?? false
    }
}

/// The ticket page's and the ticket list's Move to… menu (TP-1328): every phase Symphony's one state machine has, in
/// board order, the ticket's own checked and disabled. Picking one opens `MoveSheet`, nothing moves before its button.
public struct TicketMoveMenu: Equatable {
    public static let title = "Move to…"

    /// One entry of the menu.
    public struct Entry: Equatable, Identifiable {
        public var phase: MachinePhase
        /// The phase the ticket is in: checked and disabled.
        public var isCurrent: Bool

        public var id: String { phase.name }
        public var name: String { phase.name }
    }

    public var identifier: String
    public var current: String?
    public var entries: [Entry]

    /// The menu for ticket `identifier` in phase `current`, nil when there is nothing to offer: a Symphony that
    /// predates the `phases` list, or a ticket in no repository Symphony is configured for, which it refuses to move.
    public init?(identifier: String, current: String?, repoKey: String?, phases: [MachinePhase]) {
        guard !phases.isEmpty, repoKey?.isEmpty == false else { return nil }
        self.identifier = identifier
        self.current = current
        entries = phases.map { Entry(phase: $0, isCurrent: Self.same($0.name, current)) }
    }

    /// The phases the state payload lists, empty when it lists none or doesn't read.
    public static func phases(inState data: Data?) -> [MachinePhase] {
        struct Payload: Decodable {
            let phases: [MachinePhase]?
        }
        guard let data, let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return [] }
        return payload.phases ?? []
    }

    /// The sheet a pick opens, nil for the phase the ticket is in.
    public func sheet(for entry: Entry) -> MoveSheet? {
        entry.isCurrent ? nil : MoveSheet(identifier: identifier, from: current, to: entry.phase)
    }

    /// What VoiceOver says for an entry.
    public static func accessibilityLabel(_ entry: Entry) -> String {
        entry.isCurrent ? "\(entry.name), the phase it is in" : "Move to \(entry.name)"
    }

    /// Phase names compare as Symphony compares them: trimmed and case-insensitive.
    static func same(_ name: String, _ other: String?) -> Bool {
        guard let other else { return false }
        return name.trimmingWhitespace().lowercased() == other.trimmingWhitespace().lowercased()
    }
}

/// The move's consequence sheet: the title is the question, then what happens and what stays, an optional note, and
/// Cancel with the move's button. Its button sends `POST /api/v1/control/move`.
public struct MoveSheet: Equatable, Identifiable {
    public static let notePrompt = "Note on the ticket's timeline"
    public static let notePlaceholder = "Why it moves (optional)"

    public var identifier: String
    /// The phase it leaves, when the page knows it.
    public var from: String?
    public var to: MachinePhase

    public var id: String { "\(identifier)→\(to.name)" }

    public init(identifier: String, from: String?, to: MachinePhase) {
        self.identifier = identifier
        self.from = from
        self.to = to
    }

    public var title: String { "Move \(identifier) to \(to.name)?" }

    /// What happens: the move, and whether a run starts there.
    public var happens: String {
        let move = from.map { "Moves \(identifier) from \($0) to \(to.name)" } ?? "Moves \(identifier) to \(to.name)"
        return to.dispatches
            ? move + ", and Symphony starts its run there at once."
            : move + ". Symphony starts no run there."
    }

    /// What stays the same.
    public var stays: String {
        "Its workspace, branch and pull request stay as they are. Undo on the banner puts it back within 10 seconds."
    }

    /// The button.
    public var verb: String { "Move to \(to.name)" }

    /// The request the button sends: the note when one was typed.
    public func action(note: String) -> ControlAction {
        let note = note.trimmingWhitespace()
        return .move(identifier, to: to.name, note: note.isEmpty ? nil : note)
    }

    /// The banner once Symphony answered: Undo only when the ticket moved.
    public func banner(after outcome: MoveOutcome) -> InboxBanner {
        let state = outcome.toState ?? to.name
        if outcome.moved {
            return InboxBanner(itemID: identifier, identifier: identifier, text: "Moved to \(state)", undo: true)
        }
        return InboxBanner(itemID: identifier, identifier: identifier, text: "Already in \(state)", undo: false, style: .info)
    }

    /// What Symphony is expected to answer, for an answer that didn't say.
    public var expectedOutcome: MoveOutcome { MoveOutcome(moved: true, toState: to.name) }
}
