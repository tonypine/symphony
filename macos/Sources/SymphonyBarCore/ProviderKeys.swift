import Foundation

/// The providers Symphony reaches with an API key the app passes it (TP-1540): OpenRouter and OpenCode Go. Anthropic
/// and OpenAI sign in through their own harness and take no key. Each key is kept with the other secrets, under the
/// variable runs read it from, and passed to Symphony only while its provider is enabled. Enable is a switch of its
/// own (D3 on TP-1524): saving or removing a key never changes it, and a provider with no key is never on.
public struct ProviderKeys: Equatable {
    /// A provider set up with an API key: its id, as Symphony's state and `symphony.yml` name it, and its variable.
    public struct Spec: Equatable {
        public let id: String
        public let name: String
        public let variable: String
    }

    public static let openRouter = Spec(id: RunProfilesConfig.openRouter, name: "OpenRouter", variable: "OPENROUTER_API_KEY")
    public static let openCodeGo = Spec(id: RunProfilesConfig.openCodeGo, name: "OpenCode Go", variable: "OPENCODE_API_KEY")
    public static let all = [openRouter, openCodeGo]

    /// The secret store account the enabled providers are kept under, as ids joined by commas. Never a variable.
    public static let enabledAccount = "SYMPHONY_ENABLED_PROVIDERS"

    /// The accounts provider keys and the enabled set take, which are never extra variables.
    public static let reservedNames = Set(all.map(\.variable)).union([enabledAccount])

    /// The spec of the provider `id`, nil for one set up without a key.
    public static func spec(_ id: String) -> Spec? { all.first { $0.id == id } }

    /// Each stored key by provider id; a provider with no key has none here.
    public private(set) var keys: [String: String]
    /// The providers the Director enabled, whether or not their key is stored.
    public private(set) var enabled: Set<String>

    public init(keys: [String: String] = [:], enabled: Set<String> = []) {
        self.keys = keys.filter { !$0.value.isEmpty }
        self.enabled = enabled
    }

    /// True when the provider `id` has a key stored.
    public func hasKey(_ id: String) -> Bool { keys[id] != nil }

    /// True when the provider `id` is on: enabled, with a key.
    public func isEnabled(_ id: String) -> Bool { enabled.contains(id) && hasKey(id) }

    /// The providers set up with a key that are not on: Factory › Runs doesn't offer them.
    public var off: Set<String> { Set(Self.all.map(\.id).filter { !isEnabled($0) }) }

    /// The variables Symphony is launched with: each enabled provider's key.
    public var environment: [String: String] {
        var environment: [String: String] = [:]
        for spec in Self.all where isEnabled(spec.id) {
            environment[spec.variable] = keys[spec.id]
        }
        return environment
    }

    /// Puts each enabled provider's key in `environment` and takes out the variable of every provider that is off, so
    /// a key reaches runs only while its provider is enabled, even one the app itself was started with.
    public func apply(to environment: inout [String: String]) {
        for spec in Self.all {
            environment[spec.variable] = isEnabled(spec.id) ? keys[spec.id] : nil
        }
    }

    /// The same keys with `key` stored for `id`; a blank key removes it. The enabled set doesn't change.
    public func setting(_ key: String, for id: String) -> ProviderKeys {
        var copy = self
        let key = key.trimmingWhitespace()
        copy.keys[id] = key.isEmpty ? nil : key
        return copy
    }

    /// The same keys with `id` enabled or not. The keys don't change.
    public func enabling(_ id: String, _ on: Bool) -> ProviderKeys {
        var copy = self
        if on { copy.enabled.insert(id) } else { copy.enabled.remove(id) }
        return copy
    }

    // MARK: The secret store

    /// Reads the keys and the enabled set. With no enabled set stored yet (an install whose OpenRouter key was saved in
    /// Settings, or an `OPENCODE_API_KEY` set there as a variable), every provider with a key starts enabled, so
    /// nothing that works today stops.
    public static func load(from store: SecretStore) throws -> ProviderKeys {
        var keys: [String: String] = [:]
        for spec in all {
            keys[spec.id] = try store.value(forAccount: spec.variable)?.trimmingWhitespace()
        }
        let loaded = ProviderKeys(keys: keys.compactMapValues { $0 })
        guard let stored = try store.value(forAccount: enabledAccount) else {
            return ProviderKeys(keys: loaded.keys, enabled: Set(loaded.keys.keys))
        }
        return ProviderKeys(keys: loaded.keys, enabled: parse(stored))
    }

    /// Writes what differs from `old` (what was read): each changed key, and the enabled set every time, so the start
    /// from the keys a migration made is kept from the first write on.
    public func save(to store: SecretStore, over old: ProviderKeys) throws {
        for spec in Self.all where keys[spec.id] != old.keys[spec.id] {
            if let key = keys[spec.id] {
                try store.setValue(key, forAccount: spec.variable)
            } else {
                try store.removeValue(forAccount: spec.variable)
            }
        }
        try store.setValue(Self.all.map(\.id).filter { enabled.contains($0) }.joined(separator: ","), forAccount: Self.enabledAccount)
    }

    static func parse(_ stored: String) -> Set<String> {
        Set(stored.split(separator: ",").map { String($0).trimmingWhitespace() }.filter { !$0.isEmpty })
    }
}
