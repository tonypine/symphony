import Foundation

/// N9, "Where this ticket sits": the last card of an Inbox review, from the item's `context` and its request's
/// `unblocks`. Each row is there only when known, and an item with no row draws no card. Pure, so each row is tested
/// against the fixtures; the app draws it.
public struct ContextCard: Equatable {
    public static let title = "Where this ticket sits"

    /// **Part of**: the parent as a chip with its title, and how far its sub-tickets are (N10).
    public struct PartOf: Equatable {
        /// "TP-870 · Simplify the review flow": the identifier is the chip.
        public var text: String
        /// Nil for a parent without sub-tickets.
        public var progress: SubTicketStrip?
    }

    /// **Connected**: a ticket blocked by, blocking or related to this one, as a chip, its situation line (C31) and
    /// the relation in words; its stage (C7) only from a Symphony that serves no situation for it.
    public struct Connection: Equatable {
        public var identifier: String
        public var situation: Situation?
        public var stage: ReferencePopover.Badge?
        /// "waits on TP-892", "TP-892 waits on it", "related".
        public var relation: String
    }

    /// **Earlier calls**: a decision already made on the ticket.
    public struct EarlierCall: Equatable {
        /// "05:48" today, "Oct 7, 05:48" before; nil when Symphony couldn't tell.
        public var time: String?
        /// "Keep the Supervisor check's log for a week · You chose “Remove it with the rest”".
        public var text: String
    }

    /// **Now**: where the item's ticket stands, the line every page shows for it; nil when the state holds none.
    public var situation: Situation?
    public var partOf: PartOf?
    /// **Its work**: "#448 · reviewing · CI red on test · sent back twice", the number a chip; only the number when
    /// the ticket's situation line says where it stands.
    public var work: String?
    public var connected: [Connection]
    /// **Your answer**: what answering unblocks, as a sentence.
    public var answer: String?
    public var earlierCalls: [EarlierCall]
    /// The item's `references` and, for a ticket of the card they don't name, what the context says of it, so each
    /// chip in the card has its popover.
    public var references: [String: Reference]

    /// The card for `item`; nil when it would have no row. `now` and `calendar` tell an earlier call from today
    /// from an older one. `state` gives each ticket's situation (`StateSnapshot.situations`).
    public init?(item: InboxItem, now: Date = Date(), calendar: Calendar = .current, state: StateSnapshot? = nil) {
        let context = item.context ?? TicketContext()
        let situation = state?.situation(item.identifier)
        self.situation = situation
        var references = item.references
        let addTicket = { (identifier: String, title: String?, state: String?) in
            if references[identifier] == nil {
                references[identifier] = .ticket(Reference.Ticket(identifier: identifier, title: title, state: state))
            }
        }

        partOf = context.parent.map { parent in
            addTicket(parent.identifier, parent.title, nil)
            return PartOf(
                text: [parent.identifier, parent.title].compactMap { $0 }.joined(separator: " · "),
                progress: SubTicketStrip(parent)
            )
        }

        work = context.pullRequest.map { pullRequest in
            let key = ["#\(pullRequest.number)", "PR #\(pullRequest.number)"].first { references[$0] != nil } ?? "#\(pullRequest.number)"
            if references[key] == nil { references[key] = .missing(url: pullRequest.url) }
            let checks = pullRequest.failingCheck.map { "CI red on \($0)" } ?? pullRequest.checks?.state
            guard situation == nil else { return key }
            return ([key, pullRequest.review, checks, Self.sentBack(pullRequest.sentBack)].compactMap { $0 }).joined(separator: " · ")
        }

        let ticket = item.identifier
        let groups: [([TicketContext.Connected], String)] = [
            (context.blockedBy, "\(ticket) waits on it"),
            (context.blocks, "waits on \(ticket)"),
            (context.related, "related"),
        ]
        connected = groups.flatMap { list, relation in
            list.map { connected in
                addTicket(connected.identifier, connected.title, connected.state)
                let situation = state?.situation(connected.identifier)
                return Connection(
                    identifier: connected.identifier,
                    situation: situation,
                    stage: situation != nil ? nil : connected.state.map { ReferencePopover.Badge(status: ReferencePopover.status(state: $0, waitingOn: nil), word: $0) },
                    relation: relation
                )
            }
        }

        answer = item.review.action?.unblocks.flatMap(Self.sentence)

        earlierCalls = context.earlierDecisions.compactMap { decision in
            let parts = [decision.title, decision.answer.map { "You chose “\($0)”" }].compactMap { $0 }
            guard !parts.isEmpty else { return nil }
            return EarlierCall(time: decision.at.map { Self.time($0, now: now, calendar: calendar) }, text: parts.joined(separator: " · "))
        }

        self.references = references
        if situation == nil && partOf == nil && work == nil && connected.isEmpty && answer == nil && earlierCalls.isEmpty { return nil }
    }

    /// "sent back twice"; nil when Code Review never sent it back.
    static func sentBack(_ times: Int) -> String? {
        switch times {
        case ...0: nil
        case 1: "sent back once"
        case 2: "sent back twice"
        default: "sent back \(times) times"
        }
    }

    /// "Unblocks the Release workflow on main."; nil when blank.
    static func sentence(_ unblocks: String) -> String? {
        let text = unblocks.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let opening = text.lowercased().hasPrefix("unblocks ") ? "U" + text.dropFirst() : "Unblocks \(text)"
        return [".", "!", "?", "…"].contains(where: opening.hasSuffix) ? opening : opening + "."
    }

    /// "05:48" for a time today in `calendar`'s time zone, else its date with the time: "Oct 7, 05:48", and the year
    /// once it isn't this one.
    static func time(_ date: Date, now: Date, calendar: Calendar) -> String {
        let locale = calendar.locale ?? .current
        let clock = SharedDateFormatter.string(date, format: "HH:mm", locale: locale, calendar: calendar)
        guard !calendar.isDate(date, inSameDayAs: now) else { return clock }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        let day = SharedDateFormatter.string(date, format: sameYear ? "MMMd" : "yMMMd", template: true, locale: locale, calendar: calendar)
        return "\(day), \(clock)"
    }
}

/// N10: a parent's sub-tickets as a strip of segments in landing order, each coloured by its state, with how many
/// are done in words beside it, so the color is never the only signal.
public struct SubTicketStrip: Equatable {
    public enum Segment: Equatable {
        case done, working, waitingOnYou, notStarted

        /// A sub-ticket's Linear state type: "completed", "started", "triage", or not started.
        init(stateType: String) {
            switch stateType {
            case "completed": self = .done
            case "started": self = .working
            case "triage": self = .waitingOnYou
            default: self = .notStarted
            }
        }

        /// The strip's item: done, working (it breathes), waiting on you, or not started.
        public var item: DesignTokens.ProgressStrip.Item {
            switch self {
            case .done: DesignTokens.ProgressStrip.Item(.done)
            case .working: DesignTokens.ProgressStrip.Item(.working, live: true)
            case .waitingOnYou: DesignTokens.ProgressStrip.Item(.you)
            case .notStarted: DesignTokens.ProgressStrip.Item(nil)
            }
        }

        /// The segment's colour on the strip: `status.done`, `status.working`, `status.you`, or the strip's rest colour
        /// for one not started.
        public var color: DesignTokens.ColorToken { DesignTokens.ProgressStrip.color(item.status) }
    }

    public var segments: [Segment]
    public var done: Int
    public var total: Int

    /// Nil for a parent without sub-tickets.
    init?(_ parent: TicketContext.Parent) {
        guard parent.total > 0 || !parent.children.isEmpty else { return nil }
        segments = parent.children.map(Segment.init(stateType:))
        done = parent.done
        total = max(parent.total, parent.children.count)
    }

    /// One strip item per sub-ticket, in landing order.
    public var items: [DesignTokens.ProgressStrip.Item] { segments.map(\.item) }

    /// "4 of 7 done".
    public var line: String { "\(done) of \(total) done" }
    /// "4 of 7 sub-tickets done".
    public var accessibilityLabel: String { "\(done) of \(total) \(total == 1 ? "sub-ticket" : "sub-tickets") done" }
}

extension Reference.Checks {
    /// The checks in a word for the context card: "checks passing", "checks failing", "checks running".
    public var state: String {
        switch self {
        case .passed: "checks passing"
        case .failed: "checks failing"
        case .pending: "checks running"
        }
    }
}
