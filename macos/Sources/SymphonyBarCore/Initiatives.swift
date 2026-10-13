import Foundation

/// The plan tickets Symphony follows to done (D5), as `GET /api/v1/initiatives` serves them. Symphony builds the list
/// on its own poll, so reading it costs no Linear request.
public struct InitiativesPayload: Equatable {
    public static let path = "api/v1/initiatives"

    public var initiatives: [Initiative]

    public init(initiatives: [Initiative]) {
        self.initiatives = initiatives
    }

    /// The initiatives in a payload, nil when it isn't one (an error, or not JSON).
    public static func decode(_ data: Data) -> InitiativesPayload? {
        guard let payload = try? InboxPayload.decoder.decode(Payload.self, from: data), payload.error == nil,
            let initiatives = payload.initiatives
        else { return nil }
        return InitiativesPayload(initiatives: initiatives.compactMap(Initiative.init))
    }

    struct Payload: Decodable {
        struct Failure: Decodable {
            let code: String?
        }

        let initiatives: [Initiative.Payload]?
        let error: Failure?
    }
}

/// A stage of an initiative's progress bar, in the bar's order (C12). Each has a status color, a symbol and a word,
/// so the bar never relies on color alone.
public enum InitiativeStage: String, CaseIterable, Equatable {
    case done, working, you, queued, blocked

    public var word: String {
        switch self {
        case .done: "Done"
        case .working: "Working"
        case .you: "Waiting on you"
        case .queued: "Queued"
        case .blocked: "Blocked"
        }
    }

    /// The status color the segment takes; queued and blocked share the idle hue, blocked a lighter step of it.
    public var status: DesignTokens.Status {
        switch self {
        case .done: .done
        case .working: .working
        case .you: .you
        case .queued, .blocked: .idle
        }
    }

    public var symbol: String {
        switch self {
        case .done: DesignTokens.Status.done.symbol
        case .working: DesignTokens.Status.working.symbol
        case .you: DesignTokens.Status.you.symbol
        case .queued: "clock"
        case .blocked: "lock"
        }
    }

    /// Whether the segment is drawn a lighter step of its hue.
    public var isLight: Bool { self == .blocked }
}

/// What a sub-ticket waits on.
public enum InitiativeWait: Equatable {
    case done
    case working
    case you
    /// The open tickets it is blocked by.
    case blocker([String])
    case ci
    case slot

    init(_ raw: String?, waitingFor: [String]) {
        switch raw {
        case "done": self = .done
        case "working": self = .working
        case "you": self = .you
        case "blocker": self = .blocker(waitingFor)
        case "ci": self = .ci
        default: self = .slot
        }
    }

    public var stage: InitiativeStage {
        switch self {
        case .done: .done
        case .working, .ci: .working
        case .you: .you
        case .blocker: .blocked
        case .slot: .queued
        }
    }

    /// The row's line: "Waits on you", "Waits on BIL-205".
    public var line: String {
        switch self {
        case .done: "Done"
        case .working: "Working"
        case .you: "Waits on you"
        case let .blocker(identifiers) where !identifiers.isEmpty:
            "Waits on \(ListFormatter.localizedString(byJoining: identifiers))"
        case .blocker: "Waits on a blocker"
        case .ci: "Waits on CI"
        case .slot: "Waits on a slot"
        }
    }
}

/// One plan ticket and its sub-tickets.
public struct Initiative: Equatable, Identifiable {
    public enum Group: String, CaseIterable, Equatable {
        case active
        case inReview = "in_review"
        case done

        public var title: String {
            switch self {
            case .active: "Active"
            case .inReview: "In review"
            case .done: "Done recently"
            }
        }
    }

    public struct SubTicket: Equatable, Identifiable {
        public var issueID: String?
        public var identifier: String
        public var title: String?
        public var state: String?
        public var url: URL?
        public var blockedBy: [String]
        public var waits: InitiativeWait
        public var id: String { identifier }

        public init(
            issueID: String? = nil, identifier: String, title: String? = nil, state: String? = nil, url: URL? = nil,
            blockedBy: [String] = [], waits: InitiativeWait
        ) {
            self.issueID = issueID
            self.identifier = identifier
            self.title = title
            self.state = state
            self.url = url
            self.blockedBy = blockedBy
            self.waits = waits
        }
    }

    /// The initiative's line in the epic lanes.
    public struct Slot: Equatable {
        public var status: String
        public var identifier: String?
        public var reason: String?
        public var position: Int?

        public var line: String {
            switch status {
            case "running": identifier.map { "Holds a lane, running \($0)" } ?? "Holds a lane"
            case "waiting": identifier.map { "Holds a lane for \($0)" } ?? "Holds a lane"
            case "yielded": "Gave up its lane" + (reason.map { ": \($0)" } ?? "")
            case "queued": position.map { "Queued for a lane, \(ordinal($0))" } ?? "Queued for a lane"
            default: status
            }
        }

        private func ordinal(_ position: Int) -> String {
            let formatter = NumberFormatter()
            formatter.numberStyle = .ordinal
            return formatter.string(from: NSNumber(value: position)) ?? "\(position)"
        }
    }

    public var issueID: String
    public var identifier: String
    public var title: String?
    public var state: String?
    public var repoKey: String?
    public var url: URL?
    public var group: Group
    public var subTickets: [SubTicket]
    public var slot: Slot?

    public var id: String { issueID }

    /// The number of sub-tickets in each stage, in the bar's order.
    public var counts: [(stage: InitiativeStage, count: Int)] {
        InitiativeStage.allCases.map { stage in (stage, subTickets.filter { $0.waits.stage == stage }.count) }
    }

    public var doneCount: Int { subTickets.filter { $0.waits == .done }.count }

    /// "4 of 8 done".
    public var progress: String { "\(doneCount) of \(subTickets.count) done" }

    /// The detail's sentence: "4 of 8 done. BIL-206 waits on you, and 2 tickets wait on it."
    public var sentence: String {
        guard !subTickets.isEmpty else { return "No sub-tickets yet." }
        var sentence = progress + "."
        if let waiting = subTickets.first(where: { $0.waits == .you }) {
            let dependents = subTickets.filter { $0.waits != .done && $0.blockedBy.contains(waiting.identifier) }.count
            sentence += " \(waiting.identifier) waits on you"
            switch dependents {
            case 0: sentence += "."
            case 1: sentence += ", and 1 ticket waits on it."
            default: sentence += ", and \(dependents) tickets wait on it."
            }
            let others = subTickets.filter { $0.waits == .you }.count - 1
            if others > 0 { sentence += " \(others) more \(others == 1 ? "waits" : "wait") on you." }
        } else if doneCount == subTickets.count {
            sentence += " Every sub-ticket is done."
        }
        return sentence
    }

    /// The legend under the bar: each stage with sub-tickets in it, "3 Done".
    public var legend: [(stage: InitiativeStage, count: Int)] { counts.filter { $0.count > 0 } }

    /// What VoiceOver reads for the bar: "4 of 8 done: 4 done, 1 working, 1 waiting on you, 2 blocked".
    public var barAccessibilityLabel: String {
        let parts = legend.map { "\($0.count) \($0.stage.word.lowercased())" }
        return parts.isEmpty ? progress : progress + ": " + parts.joined(separator: ", ")
    }

    init?(_ payload: Payload) {
        guard let issueID = payload.issueId, let identifier = payload.identifier,
            let group = payload.group.flatMap(Group.init(rawValue:))
        else { return nil }
        self.issueID = issueID
        self.identifier = identifier
        title = payload.title
        state = payload.state
        repoKey = payload.repoKey
        url = payload.url.flatMap(URL.init(string:))
        self.group = group
        subTickets = (payload.subTickets ?? []).compactMap(SubTicket.init)
        slot = payload.slot.flatMap { slot in
            slot.status.map { Slot(status: $0, identifier: slot.identifier, reason: slot.reason, position: slot.position) }
        }
    }

    public init(
        issueID: String, identifier: String, title: String?, state: String? = nil, repoKey: String?, url: URL? = nil,
        group: Group, subTickets: [SubTicket], slot: Slot? = nil
    ) {
        self.issueID = issueID
        self.identifier = identifier
        self.title = title
        self.state = state
        self.repoKey = repoKey
        self.url = url
        self.group = group
        self.subTickets = subTickets
        self.slot = slot
    }

    struct Payload: Decodable {
        struct SubTicketPayload: Decodable {
            let issueId: String?
            let identifier: String?
            let title: String?
            let state: String?
            let url: String?
            let blockedBy: [String]?
            let waitsOn: String?
            let waitingFor: [String]?
        }

        struct SlotPayload: Decodable {
            let status: String?
            let identifier: String?
            let reason: String?
            let position: Int?
        }

        let issueId: String?
        let identifier: String?
        let title: String?
        let state: String?
        let repoKey: String?
        let url: String?
        let group: String?
        let subTickets: [SubTicketPayload]?
        let slot: SlotPayload?
    }
}

extension Initiative.SubTicket {
    init?(_ payload: Initiative.Payload.SubTicketPayload) {
        guard let identifier = payload.identifier else { return nil }
        self.init(
            issueID: payload.issueId, identifier: identifier, title: payload.title, state: payload.state,
            url: payload.url.flatMap(URL.init(string:)), blockedBy: payload.blockedBy ?? [],
            waits: InitiativeWait(payload.waitsOn, waitingFor: payload.waitingFor ?? [])
        )
    }

    /// What VoiceOver reads for the row: "BIL-206, Refund flow, waits on you, blocked by BIL-205".
    public var accessibilityLabel: String {
        var parts = [identifier]
        if let title { parts.append(title) }
        parts.append(Self.spoken(waits.line))
        if !blockedBy.isEmpty { parts.append("blocked by " + ListFormatter.localizedString(byJoining: blockedBy)) }
        return parts.joined(separator: ", ")
    }

    /// A line read mid-sentence: only its first letter lowercased, so identifiers keep their case
    /// ("Waits on BIL-206" reads "waits on BIL-206").
    public static func spoken(_ line: String) -> String {
        guard let first = line.first else { return line }
        return first.lowercased() + line.dropFirst()
    }
}

/// The Initiatives list under the window's scope, grouped as Active, In review and Done recently.
public struct InitiativesList: Equatable {
    public struct Section: Equatable, Identifiable {
        public var group: Initiative.Group
        public var initiatives: [Initiative]
        public var id: String { group.rawValue }
        public var title: String { group.title }
    }

    public static let emptyTitle = "No initiatives."
    public static let emptyDescription = "Plans you approve show here until a week after they are done."

    public var sections: [Section]

    public init(initiatives: [Initiative], scope: OverviewScope = .all) {
        let shown = initiatives.filter { scope.includes($0.repoKey) }
        sections = Initiative.Group.allCases.compactMap { group in
            let inGroup = shown.filter { $0.group == group }
            return inGroup.isEmpty ? nil : Section(group: group, initiatives: inGroup)
        }
    }

    public var ordered: [Initiative] { sections.flatMap(\.initiatives) }
    public var isEmpty: Bool { sections.isEmpty }

    /// The active initiatives, for the Overview's card.
    public var active: [Initiative] { ordered.filter { $0.group == .active } }

    /// The initiative to show: the one selected while it is still listed, else the first.
    public func selection(_ id: String?) -> Initiative? {
        ordered.first { $0.id == id } ?? ordered.first
    }
}
