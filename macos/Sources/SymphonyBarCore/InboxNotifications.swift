import Foundation

/// What notifies (D14, DD8, P11): a new Inbox item of each kind, and a new problem in Needs attention. Each can be
/// turned off in Settings.
public enum NoticeKind: String, CaseIterable, Equatable {
    case plan, pr, finalVerification, action, clarify, problem

    /// The switch's title in Settings.
    public var settingsTitle: String {
        switch self {
        case .plan: "Plans to approve"
        case .pr: "Pull requests to review"
        case .finalVerification: "Final verifications to sign off"
        case .action: "Actions only you can do"
        case .clarify: "Tickets the quality gate holds"
        case .problem: "Problems that need attention"
        }
    }

    init?(_ kind: StateSnapshot.WaitingTicket.Kind) {
        switch kind.inboxKind {
        case .plan?: self = .plan
        case .pr?: self = .pr
        case .finalVerification?: self = .finalVerification
        case .action?: self = .action
        case .clarify?: self = .clarify
        case nil: return nil
        }
    }
}

/// Which kinds notify, kept in the app's defaults; every kind is on until turned off.
public struct NotificationPreferences: Equatable {
    public static let defaultsKey = "SymphonyNotificationsOff"

    public var off: Set<NoticeKind>

    public init(off: Set<NoticeKind> = []) {
        self.off = off
    }

    public static func load(from defaults: KeyValueStore) -> NotificationPreferences {
        let names = defaults.object(forKey: defaultsKey) as? [String] ?? []
        return NotificationPreferences(off: Set(names.compactMap(NoticeKind.init(rawValue:))))
    }

    public func save(to defaults: KeyValueStore) {
        defaults.set(NoticeKind.allCases.filter(off.contains).map(\.rawValue), forKey: Self.defaultsKey)
    }

    public func isOn(_ kind: NoticeKind) -> Bool { !off.contains(kind) }

    public mutating func set(_ kind: NoticeKind, on: Bool) {
        if on { off.remove(kind) } else { off.insert(kind) }
    }
}

/// One notification: "BIL-206 waits on you" / "Pull request: Proration for plan changes", with Open.
public struct InboxNotice: Equatable {
    public var key: String
    public var kind: NoticeKind
    public var title: String
    public var body: String
    /// The Inbox item Open selects; nil for a problem, which Open shows on the Overview.
    public var issueID: String?
}

/// Decides what to notify from each state poll: an item or problem notifies once, the first time it is seen, and
/// never again for the same key, even after a relaunch (the keys are kept in the app's defaults). The first poll
/// after the app's first launch only remembers what is there, so nothing already waiting floods in.
public struct InboxNotifier: Equatable {
    public static let defaultsKey = "SymphonyNotifiedKeys"
    /// The most keys remembered; the oldest go first.
    public static let keyLimit = 500

    /// The keys notified, or seen while their kind was off, oldest first; nil before the first poll ever.
    public private(set) var remembered: [String]?

    public init(remembered: [String]? = nil) {
        self.remembered = remembered
    }

    public static func load(from defaults: KeyValueStore) -> InboxNotifier {
        InboxNotifier(remembered: defaults.object(forKey: defaultsKey) as? [String])
    }

    public func save(to defaults: KeyValueStore) {
        defaults.set(remembered, forKey: Self.defaultsKey)
    }

    /// The notices due for `waiting` and `problems`, with the kinds `preferences` turned off left out. Every item
    /// seen is remembered, so a kind turned back on doesn't notify what is already there.
    public mutating func notices(
        waiting: [StateSnapshot.WaitingTicket],
        problems: [Overview.Problem],
        preferences: NotificationPreferences
    ) -> [InboxNotice] {
        let current = waiting.compactMap(Self.notice) + problems.map(Self.notice)
        guard var known = remembered else {
            remembered = Array(current.map(\.key).suffix(Self.keyLimit))
            return []
        }
        let knownSet = Set(known)
        let new = current.filter { !knownSet.contains($0.key) }
        known.append(contentsOf: new.map(\.key))
        remembered = Array(known.suffix(Self.keyLimit))
        return new.filter { preferences.isOn($0.kind) }
    }

    static func notice(_ ticket: StateSnapshot.WaitingTicket) -> InboxNotice? {
        guard let kind = NoticeKind(ticket.kind) else { return nil }
        let what = [ticket.headline, ticket.title].compactMap { $0?.trimmingWhitespace() }.first { !$0.isEmpty }
        return InboxNotice(
            key: "\(kind.rawValue):\(ticket.issueID ?? ticket.identifier)",
            kind: kind,
            title: "\(ticket.identifier) waits on you",
            body: [ticket.kind.inboxKind?.word, what].compactMap { $0 }.joined(separator: ": "),
            issueID: ticket.issueID ?? ticket.identifier
        )
    }

    static func notice(_ problem: Overview.Problem) -> InboxNotice {
        InboxNotice(
            key: "problem:\(problem.id):\(problem.kinds.map { "\($0)" }.sorted().joined(separator: ","))",
            kind: .problem,
            title: problem.sentence,
            body: DesignTokens.Status.problem.word,
            issueID: nil
        )
    }
}
