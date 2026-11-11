import Foundation

/// One move of the ticket read's `moves` (TP-1403, `docs/control-api.md` § `moves`): whether the Director may make it
/// now and, when not, why, in the words the control call refuses with. `states` is `move_to`'s list of phases.
public struct TicketMoveRead: Equatable, Decodable {
    public var allowed: Bool
    /// Why it may not be made now; nil when it may.
    public var reason: String?
    /// On `move_to` only: the phases the free move may name now.
    public var states: [String]

    public init(allowed: Bool, reason: String? = nil, states: [String] = []) {
        self.allowed = allowed
        self.reason = reason
        self.states = states
    }

    private enum CodingKeys: String, CodingKey { case allowed, reason, states }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        allowed = try container.decode(Bool.self, forKey: .allowed)
        let reason = try container.decodeIfPresent(String.self, forKey: .reason)?.trimmingWhitespace()
        self.reason = reason?.isEmpty == false ? reason : nil
        states = (try? container.decodeIfPresent([String].self, forKey: .states)) ?? []
    }
}

/// The ticket read's `moves`: every move Symphony judged, by its name in the read (`start`, `stop`, `move_to`…).
public struct TicketMoves: Equatable {
    public var entries: [String: TicketMoveRead]

    public init(_ entries: [String: TicketMoveRead]) {
        self.entries = entries
    }

    public subscript(_ name: String) -> TicketMoveRead? { entries[name] }

    /// The `moves` of a ticket payload; nil from a Symphony that sends none. An entry the app can't read is left out,
    /// so the rail never offers a move Symphony didn't judge.
    public static func of(issue data: Data?) -> TicketMoves? {
        struct Lenient: Decodable {
            let read: TicketMoveRead?
            init(from decoder: Decoder) throws { read = try? TicketMoveRead(from: decoder) }
        }
        struct Carrier: Decodable {
            let moves: [String: Lenient]?
        }
        guard let data, let moves = (try? JSONDecoder().decode(Carrier.self, from: data))?.moves else { return nil }
        return TicketMoves(moves.compactMapValues(\.read))
    }
}

/// The Action rail (C31, TP-1440): a ticket's moves in one row, from the read's `moves` and nothing else. The
/// expected move first and primary, then the common ones, then More for the rest, with Stop Run… last in More in the
/// destructive style. A move the read refuses stays in its place, disabled, with the read's reason.
public struct TicketActionRail: Equatable {
    /// The moves the rail offers, by their name in the read.
    public enum Move: String, CaseIterable, Equatable {
        case answer, start, stop, moveTo = "move_to", force, unforce, restart, unblock, cancel, note

        public var title: String {
            switch self {
            case .answer: "Answer"
            case .start: TicketStart.title
            case .stop: StopRunSheet.buttonTitle
            case .moveTo: TicketMoveMenu.title
            case .force: TicketList.forceTitle
            case .unforce: TicketList.stopForcingTitle
            case .restart: "Restart…"
            case .unblock: "Unblock"
            case .cancel: "Cancel Ticket…"
            case .note: "Write a Note…"
            }
        }
    }

    /// One move on the rail or in More.
    public struct Item: Equatable, Identifiable {
        public var move: Move
        /// Why it can't act now, from the read; nil when it can.
        public var reason: String?
        /// `move_to`'s phases.
        public var states: [String]

        public var id: String { move.rawValue }
        public var title: String { move.title }
        public var allowed: Bool { reason == nil }
        /// Stop Run… draws in the destructive style.
        public var destructive: Bool { move == .stop }
    }

    /// A sheet the host shows before the control call goes, where one asks first (C17).
    public enum Sheet: Equatable {
        /// The open Question, to pick an answer.
        case answer
        case stopRun
        case moveTo(String)
        /// The Force a Ticket sheet.
        case force
        /// Restart's reason.
        case restart
        /// The note for the next run.
        case note
    }

    /// What pressing a move asks for.
    public enum Request: Equatable {
        /// The control call, sent at once.
        case send(ControlAction)
        /// The consequence sheet, which sends the call from its own button.
        case sheet(Sheet)
        /// A yes-or-no confirmation, then the call.
        case confirm(Confirmation)
    }

    /// A move that asks before it goes and has no sheet of its own.
    public struct Confirmation: Equatable {
        public var title: String
        public var message: String
        public var button: String
        public var action: ControlAction
    }

    /// Why a move the read refuses without a reason can't act.
    public static let unknownReason = "Symphony doesn't allow this now."
    /// The moves that may be the expected one, in the order the rail picks: only a person moves a ticket waiting on
    /// an answer or held for them, then a ticket that can start.
    public static let expectedOrder: [Move] = [.answer, .unblock, .start]

    public var identifier: String
    /// The expected move: the first of `expectedOrder` the read allows; nil when none.
    public var primary: Item?
    /// The common moves after it: Start Now (unless it is the primary), then Force or Stop Forcing.
    public var secondary: [Item]
    /// The rest, in More, Stop Run… last.
    public var more: [Item]

    /// The rail for `moves`, leaving out the ones in `omitting`: the desktop ticket page's header leaves out Answer,
    /// since its decisions column is always open beside it (TP-1449).
    public init(identifier: String, moves: TicketMoves, omitting: Set<Move> = []) {
        self.identifier = identifier
        func item(_ move: Move) -> Item? {
            guard !omitting.contains(move), let read = moves[move.rawValue] else { return nil }
            return Item(move: move, reason: read.allowed ? nil : (read.reason ?? Self.unknownReason), states: read.states)
        }
        let primary = Self.expectedOrder.lazy.compactMap(item).first { $0.allowed }
        self.primary = primary
        let forcing = item(.unforce).flatMap { $0.allowed ? $0 : nil } ?? item(.force) ?? item(.unforce)
        let secondary = [item(.start), forcing].compactMap { $0 }.filter { $0.move != primary?.move }
        self.secondary = secondary
        let placed = Set([primary?.move].compactMap { $0 } + secondary.map(\.move))
        let rest: [Move] = [.answer, .unblock, .moveTo, .restart, .cancel, .note, .stop]
        more = rest.compactMap(item).filter { !placed.contains($0.move) }
    }

    /// Every move on the rail, in order: the primary, the others, then More's.
    public var items: [Item] { [primary].compactMap { $0 } + secondary + more }

    /// What pressing `move` asks for; nil when the read doesn't allow it. `state` is the phase a Move to… names.
    public func request(_ move: Move, state: String? = nil) -> Request? {
        guard items.first(where: { $0.move == move })?.allowed == true else { return nil }
        switch move {
        case .answer: return .sheet(.answer)
        case .start: return .send(TicketStart.action(identifier))
        case .stop: return .sheet(.stopRun)
        case .moveTo: return state.map { .sheet(.moveTo($0)) }
        case .force: return .sheet(.force)
        case .unforce: return .send(.stopForcing(identifier))
        case .restart: return .sheet(.restart)
        case .unblock: return .send(.unblock(identifier))
        case .note: return .sheet(.note)
        case .cancel:
            return .confirm(Confirmation(
                title: "Cancel \(identifier)?",
                message: "Symphony moves \(identifier) to Cancelled, ends any run working on it and closes its pull request.",
                button: "Cancel Ticket",
                action: .cancel(identifier, note: nil)
            ))
        }
    }

    /// What VoiceOver says for a move: its title, and why it can't act when it can't.
    public static func accessibilityLabel(_ item: Item) -> String {
        guard let reason = item.reason else { return item.title }
        return "\(item.title), unavailable: \(reason)"
    }
}
