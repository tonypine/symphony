import Foundation

/// Why a provider's reserve can't be read or changed by editing one line.
public enum ProviderReserveError: LocalizedError, Equatable {
    /// A section above the key holds an inline value (for example `providers: {anthropic: {reserve: 0.9}}`).
    case notABlock(String)
    /// The key holds something other than a share from 0 to 1 or `null`.
    case unreadable(key: String, value: String)
    /// Symphony can't read the provider's usage, so it takes no reserve.
    case notReadable(String)

    public var errorDescription: String? {
        switch self {
        case .notABlock(let key):
            return "`\(key):` in symphony.yml is not an indented block. Change the reserve by hand."
        case let .unreadable(key, value):
            return "`\(key): \(value)` in symphony.yml is not a share from 0 to 1. Change it by hand."
        case .notReadable(let provider):
            return "Symphony can't read \(RunsPage.providerTitle(provider))'s usage, so it takes no reserve."
        }
    }
}

/// Where new runs on a provider stop (TP-1535): `execution.providers.<provider>.reserve` in the text of a `symphony.yml`,
/// a share of any of its usage windows, or none. Only a provider whose usage Symphony reads takes one. Only the reserve's
/// line is rewritten, or inserted with the sections above it when missing, so the rest of the file stays as it is.
public enum ProviderReserve {
    /// The providers whose usage Symphony reads (`SymphonyElixir.Providers.usage_readable/0`).
    public static let usageReadable: Set<String> = ["anthropic"]

    /// The shares "Stop new runs at" offers, in whole percent, before "No reserve".
    public static let choices = [50, 60, 70, 75, 80, 85, 90, 95]

    /// The words for no reserve: new runs go on until the limit is reached.
    public static let noneTitle = "No reserve"

    static func path(_ provider: String) -> [String] { ["execution", "providers", provider, "reserve"] }

    /// Whether `provider` takes a reserve.
    public static func takesReserve(_ provider: String) -> Bool { usageReadable.contains(provider) }

    /// `share` (0 to 1) as a whole percent: 0.9 is 90.
    public static func percent(_ share: Double) -> Int { Int((share * 100).rounded()) }

    /// The reserve of `provider` in `yaml` as a whole percent, nil when it has none.
    public static func value(of provider: String, in yaml: String) throws -> Int? {
        let path = path(provider)
        let value = try blockSection { try ConfigSetting.value(at: path, of: yaml) }
        guard let value, !TokenLimits.nullValues.contains(value) else { return nil }
        guard let share = Double(value), share > 0, share <= 1 else {
            throw ProviderReserveError.unreadable(key: path.joined(separator: "."), value: value)
        }
        return percent(share)
    }

    /// The same text with the reserve of `provider` set to `percent` (as a share: 90 is `0.9`), or to `null` for none.
    public static func setting(_ percent: Int?, of provider: String, in yaml: String) throws -> String {
        guard takesReserve(provider) else { throw ProviderReserveError.notReadable(provider) }
        let value = percent.map { share($0) } ?? "null"
        return try blockSection { try ConfigSetting.setting(at: path(provider), to: value, in: yaml) }
    }

    /// `percent` as the share YAML holds: 90 is `0.9`, 85 is `0.85`.
    static func share(_ percent: Int) -> String {
        let clamped = min(max(percent, 1), 100)
        let tenths = clamped % 10 == 0
        return clamped == 100 ? "1" : String(format: tenths ? "0.%d" : "0.%02d", tenths ? clamped / 10 : clamped)
    }

    /// Reports an inline section as a reserve error.
    private static func blockSection<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch MaxConcurrentAgentsError.notABlock(let key) {
            throw ProviderReserveError.notABlock(key)
        }
    }
}

extension SymphonyConfigFile {
    public func readProviderReserve(of provider: String) throws -> Int? {
        try ProviderReserve.value(of: provider, in: read())
    }

    /// Sets the reserve of `provider` to `percent` (nil for none), once `check` passes on the result.
    public func writeProviderReserve(
        _ percent: Int?,
        of provider: String,
        checkingWith check: (String) async -> ConfigCheckResult
    ) async throws -> ConfigCheckResult {
        try await rewrite({ try ProviderReserve.setting(percent, of: provider, in: $0) }, checkingWith: check)
    }
}
