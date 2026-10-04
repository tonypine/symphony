import Foundation

/// Why `agent.limits.tokens_per_day` or `.tokens_per_issue` can't be read or changed by editing one line.
public enum TokenLimitsError: LocalizedError, Equatable {
    /// The key holds an inline value (for example `limits: {tokens_per_day: 5}`) instead of an indented block.
    case notABlock(String)
    /// The key holds something other than a whole number or `null`.
    case unreadable(key: String, value: String)

    public var errorDescription: String? {
        switch self {
        case .notABlock(let key):
            return "`\(key):` in symphony.yml is not an indented block. Change the token limits by hand."
        case let .unreadable(key, value):
            return "`\(key): \(value)` in symphony.yml is not a whole number or null. Change it by hand."
        }
    }
}

/// A token cap: off (`null` in symphony.yml) or a number of tokens.
public enum TokenLimit: Equatable {
    case off
    case tokens(Int)
}

/// `agent.limits.tokens_per_day` and `agent.limits.tokens_per_issue` in the text of a `symphony.yml`. Only the
/// lines of the limits that change are rewritten, or inserted when missing, so the rest of the file stays as it is.
public struct TokenLimits: Equatable {
    public var perDay: TokenLimit
    public var perIssue: TokenLimit

    /// What Symphony uses when a key is missing.
    public static let defaultPerDay = 5_000_000
    public static let defaultPerIssue = 500_000

    static let section = "limits"
    static let perDayKey = "tokens_per_day"
    static let perIssueKey = "tokens_per_issue"

    /// The values YAML reads as null, which turn a cap off. An empty value is null too.
    static let nullValues: Set<String> = ["", "~", "null", "Null", "NULL"]

    public init(perDay: TokenLimit = .tokens(defaultPerDay), perIssue: TokenLimit = .tokens(defaultPerIssue)) {
        self.perDay = perDay
        self.perIssue = perIssue
    }

    /// Both limits, with Symphony's default for a missing key.
    public static func values(in yaml: String) throws -> TokenLimits {
        TokenLimits(
            perDay: try limit(perDayKey, default: defaultPerDay, in: yaml),
            perIssue: try limit(perIssueKey, default: defaultPerIssue, in: yaml)
        )
    }

    /// The same text with the limits that differ between `old` and `new` set to their `new` values.
    public static func updating(_ yaml: String, from old: TokenLimits, to new: TokenLimits) throws -> String {
        var yaml = yaml
        if new.perDay != old.perDay { yaml = try setting(perDayKey, to: new.perDay, in: yaml) }
        if new.perIssue != old.perIssue { yaml = try setting(perIssueKey, to: new.perIssue, in: yaml) }
        return yaml
    }

    private static func limit(_ key: String, default defaultTokens: Int, in yaml: String) throws -> TokenLimit {
        let value = try blockSection { try AgentSetting.value(key, in: section, of: yaml) }
        guard let value else { return .tokens(defaultTokens) }
        if nullValues.contains(value) { return .off }
        guard let tokens = Int(value) else { throw TokenLimitsError.unreadable(key: key, value: value) }
        return .tokens(tokens)
    }

    private static func setting(_ key: String, to limit: TokenLimit, in yaml: String) throws -> String {
        let value: String
        switch limit {
        case .off:
            value = "null"
        case .tokens(let tokens):
            value = String(tokens)
        }
        return try blockSection { try AgentSetting.setting(key, in: section, to: value, in: yaml) }
    }

    /// Reports an inline `agent:` or `limits:` as a token limits error.
    private static func blockSection<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch MaxConcurrentAgentsError.notABlock(let key) {
            throw TokenLimitsError.notABlock(key)
        }
    }

    /// For example "1B", "156.5M", "500K" or "999".
    public static func compact(_ tokens: Int) -> String {
        guard abs(tokens) >= 1_000 else { return String(tokens) }
        for (unit, suffix) in [(1e9, "B"), (1e6, "M"), (1e3, "K")] {
            let scaled = (Double(tokens) / unit * 10).rounded() / 10
            if abs(scaled) >= 1 {
                let number = scaled == scaled.rounded() ? String(Int(scaled)) : String(scaled)
                return number + suffix
            }
        }
        return String(tokens)
    }

    /// For example "1,000,000,000".
    public static func grouped(_ tokens: Int) -> String {
        tokens.formatted(.number.locale(Locale(identifier: "en_US")))
    }
}

/// A token cap as Settings edits it: a switch, and the number typed while it's on.
public struct TokenLimitField: Equatable {
    public var isOn: Bool
    public var text: String

    /// Off shows `defaultTokens` in the field, for when the switch is turned on.
    public init(_ limit: TokenLimit, default defaultTokens: Int) {
        switch limit {
        case .off:
            isOn = false
            text = String(defaultTokens)
        case .tokens(let tokens):
            isOn = true
            text = String(tokens)
        }
    }

    /// The cap, or nil while the switch is on and the text isn't a whole number.
    public var limit: TokenLimit? {
        guard isOn else { return .off }
        return tokens.map(TokenLimit.tokens)
    }

    /// The typed number, with grouping commas, underscores and spaces left out.
    var tokens: Int? {
        Int(text.filter { !",_ ".contains($0) }.trimmingWhitespace())
    }

    /// "2,000,000,000 = 2B" for the typed number, or what to type instead.
    public var hint: String {
        guard let tokens else { return "Enter a whole number of tokens, such as 1000000000" }
        return "\(TokenLimits.grouped(tokens)) = \(TokenLimits.compact(tokens))"
    }
}

extension SymphonyConfigFile {
    public func readTokenLimits() throws -> TokenLimits {
        try TokenLimits.values(in: read())
    }

    /// Sets the limits that differ between `old` and `new`, once `check` passes on the result.
    public func writeTokenLimits(
        _ new: TokenLimits,
        from old: TokenLimits,
        checkingWith check: (String) async -> ConfigCheckResult
    ) async throws -> ConfigCheckResult {
        try await rewrite({ try TokenLimits.updating($0, from: old, to: new) }, checkingWith: check)
    }

    /// Runs `check` on a copy of the file with the limits set, without changing the file.
    public func checkTokenLimits(
        _ new: TokenLimits,
        from old: TokenLimits,
        with check: (String) async -> ConfigCheckResult
    ) async throws -> ConfigCheckResult {
        try await checking({ try TokenLimits.updating($0, from: old, to: new) }, with: check)
    }
}

/// Settings' lines about today's tokens, from `/api/v1/state.budget`.
public enum TokenUsage {
    /// For example "Used today: 156.5M of 1B tokens, 843.5M left. Resets at 21:00.", followed by a line when
    /// the daily cap has paused new runs. Symphony counts the day in UTC, so it resets at UTC midnight, shown
    /// in `timeZone`.
    public static func lines(_ budget: StateSnapshot.Budget?, now: Date, timeZone: TimeZone) -> [String] {
        guard let budget else { return ["Today's usage shows while Symphony is running."] }
        let reset = "resets at \(resetTime(after: now, timeZone: timeZone))"
        let used = TokenLimits.compact(budget.dailyUsed)
        var lines: [String]
        if let limit = budget.dailyLimit {
            let left = TokenLimits.compact(budget.dailyRemaining ?? max(limit - budget.dailyUsed, 0))
            lines = ["Used today: \(used) of \(TokenLimits.compact(limit)) tokens, \(left) left. The count \(reset)."]
        } else {
            lines = ["Used today: \(used) tokens, no daily cap. The count \(reset)."]
        }
        if budget.dailyPaused {
            lines.append("New runs are paused: today's cap is used up. They resume when the count \(reset), or raise or turn off the cap.")
        }
        return lines
    }

    /// The next UTC midnight after `now`.
    public static func nextReset(after now: Date) -> Date {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        return utc.nextDate(after: now, matching: DateComponents(hour: 0, minute: 0, second: 0), matchingPolicy: .nextTime)!
    }

    /// "21:00", or "02:00 tomorrow" when the reset falls on the next day in `timeZone`.
    static func resetTime(after now: Date, timeZone: TimeZone) -> String {
        let reset = nextReset(after: now)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        let time = formatter.string(from: reset)
        return calendar.isDate(reset, inSameDayAs: now) ? time : time + " tomorrow"
    }
}
