import Foundation

/// A notification about a usage-limit hold starting or clearing.
public struct UsageLimitNotice: Equatable {
    public var title: String
    public var body: String

    public init(title: String, body: String) {
        self.title = title
        self.body = body
    }
}

/// Diffs consecutive state polls into notifications when Symphony pauses itself for a usage limit and when
/// it resumes, so each transition is announced once.
public struct UsageLimitNotices: Equatable {
    private struct Hold: Hashable {
        let provider: String
        let scope: String
    }

    /// The holds in the last state, or nil before the first state and after Symphony stopped answering, so a
    /// hold already in place then isn't announced as new.
    private var held: Set<Hold>?

    public init() {}

    /// The notifications for `poll`, given the polls before it. A canary still counts as held, and a
    /// headroom hold doesn't count: only a used-up limit pauses Symphony.
    public mutating func notices(
        for poll: StatusPoll,
        now: Date = Date(),
        timeZone: TimeZone = .current
    ) -> [UsageLimitNotice] {
        guard case let .state(snapshot) = poll else {
            held = nil
            return []
        }
        let limits = snapshot.usageLimits.filter { $0.phase != .headroom }
        let current = Set(limits.map { Hold(provider: $0.provider, scope: $0.scope) })
        defer { held = current }
        guard let previous = held else { return [] }

        var notices = limits
            .filter { $0.phase == .paused && !previous.contains(Hold(provider: $0.provider, scope: $0.scope)) }
            .map { limit in
                UsageLimitNotice(
                    title: "Symphony paused",
                    body: StatusMenu.limitName(limit)
                        + StatusMenu.approximateTime(", resumes", limit.resumeAt, now: now, timeZone: timeZone)
                )
            }
        // Dispatch stays paused while the operator pause is on, so there is nothing to announce yet.
        if snapshot.pause == nil {
            let cleared = Set(previous.map(\.provider)).subtracting(current.map(\.provider)).sorted()
            notices += cleared.map { provider in
                UsageLimitNotice(title: "Symphony resumed", body: "\(StatusMenu.providerName(provider)) limit reset")
            }
        }
        return notices
    }
}
