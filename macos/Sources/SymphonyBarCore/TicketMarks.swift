import Foundation

// The ticket's marks on its page (`docs/design/director-ticket-page.md` §1 fact 6, §2 question 4, §4; TP-1451): when
// the person last looked, read from the ticket read's `looked_at` and `new_since_looked` (`docs/control-api.md`
// § Marks), and the look itself, sent with `POST /api/v1/control/looked` once per visit.
//
// The moment of the look: when the person leaves a ticket page they had in front for at least `TicketLook.minimumVisit`
// (another place in the window, the window closing, the app quitting). Never on opening, and never from a read: a page
// kept open keeps the `looked_at` it opened with, so its marker stays where it was until the next visit, while each
// new event still comes `new` and gets its dot.

/// What the ticket read says about the person's last look.
public struct TicketMarksRead: Equatable, Decodable {
    /// When the person last looked, nil when they never did.
    public var lookedAt: Date?
    /// How many of the ticket's events are later than `lookedAt`; every one when it is nil.
    public var newSinceLooked: Int

    public init(lookedAt: Date? = nil, newSinceLooked: Int = 0) {
        self.lookedAt = lookedAt
        self.newSinceLooked = newSinceLooked
    }

    private enum CodingKeys: String, CodingKey {
        case lookedAt = "looked_at"
        case newSinceLooked = "new_since_looked"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lookedAt = try container.decodeIfPresent(String.self, forKey: .lookedAt).flatMap(SymphonyState.parseDate)
        newSinceLooked = max(try container.decodeIfPresent(Int.self, forKey: .newSinceLooked) ?? 0, 0)
    }

    /// The marks of a ticket read (`GET /api/v1/:issue_identifier`); nil for anything but a JSON object.
    public static func decode(_ data: Data) -> TicketMarksRead? {
        try? JSONDecoder().decode(TicketMarksRead.self, from: data)
    }

    /// The Timeline title's count, "3 new"; nil on a first visit, where nothing is new yet, and when nothing is.
    public var newText: String? {
        guard lookedAt != nil, newSinceLooked > 0 else { return nil }
        return "\(newSinceLooked) new"
    }

    /// The count for VoiceOver: "3 new since you last looked".
    public var newAccessibilityLabel: String? {
        newText.map { $0 + " since you last looked" }
    }

    /// The marker line's words: "Since you last looked, at 16:50", the time in `clock`'s zone.
    public static func markerText(_ lookedAt: Date, clock: (Date) -> String) -> String {
        "Since you last looked, at \(clock(lookedAt))"
    }
}

/// One visit of a ticket page and the look it sends when the person leaves it.
public struct TicketLook: Equatable {
    /// A page left sooner than this was passed through, not looked at (⌘[ through the history): it sends no look.
    public static let minimumVisit: TimeInterval = 2

    public struct Visit: Equatable {
        public var identifier: String
        public var repoKey: String?
        public var openedAt: Date
    }

    /// The page shown now, nil on any other place.
    public private(set) var visit: Visit?

    public init() {}

    /// The window now shows `identifier`'s page, or another place when nil: leaving a page answers its look, once,
    /// when it was in front long enough; the same page shown again is the same visit.
    public mutating func show(_ identifier: String?, at now: Date) -> ControlAction? {
        guard identifier != visit?.identifier else { return nil }
        let look = leave(at: now)
        visit = identifier.map { Visit(identifier: $0, repoKey: nil, openedAt: now) }
        return look
    }

    /// The page's repo, once its read says it: the look names it.
    public mutating func repoKnown(_ repoKey: String?, for identifier: String) {
        guard visit?.identifier == identifier, let repoKey, !repoKey.isEmpty else { return }
        visit?.repoKey = repoKey
    }

    /// Whether leaving now would send a look: a window closing or the app quitting waits for it.
    public func looks(at now: Date) -> Bool {
        guard let visit else { return false }
        return now.timeIntervalSince(visit.openedAt) >= Self.minimumVisit
    }

    /// The person leaves the page (the window closes, the app quits): its look, nil when it was passed through.
    public mutating func leave(at now: Date) -> ControlAction? {
        guard let visit else { return nil }
        let look = looks(at: now) ? ControlAction.looked(visit.identifier, repoKey: visit.repoKey) : nil
        self.visit = nil
        return look
    }
}
