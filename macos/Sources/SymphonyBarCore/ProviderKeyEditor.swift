import Foundation

/// The Key block's state on Factory › Providers (TP-1540): the key typed on each provider's page and not saved yet,
/// the provider under test, and the last test's result. A test that passes keeps the key; Enable is available only
/// once a test passed on the key the page holds. Editing the key clears its result.
public struct ProviderKeyEditor: Equatable {
    /// A test's result and the key it was made with.
    public struct Tested: Equatable {
        public let key: String
        public let result: ProviderKeyCheck.Result
    }

    /// The key typed on each provider's page, by id, until a test that passes keeps it.
    public private(set) var drafts: [String: String] = [:]
    /// The last test's result on each provider's page, by id.
    public private(set) var tested: [String: Tested] = [:]
    /// The provider whose key is being tested.
    public private(set) var testing: String?

    public init() {}

    /// What the key field holds for `id`: the key typed, else the key stored, else nothing.
    public func text(_ id: String, keys: ProviderKeys) -> String {
        drafts[id] ?? keys.keys[id] ?? ""
    }

    /// The Director types in the key field: the last result no longer holds.
    public mutating func edit(_ id: String, to text: String, keys: ProviderKeys) {
        guard text != self.text(id, keys: keys) else { return }
        drafts[id] = text
        tested[id] = nil
    }

    /// The result to show for `id`: the last test's, while the field still holds the key it tested.
    public func result(_ id: String, keys: ProviderKeys) -> ProviderKeyCheck.Result? {
        guard let tested = tested[id], tested.key == text(id, keys: keys).trimmingWhitespace() else { return nil }
        return tested.result
    }

    /// Test connection is on while no test runs and the field holds a key.
    public func canTest(_ id: String, keys: ProviderKeys) -> Bool {
        testing == nil && !text(id, keys: keys).trimmingWhitespace().isEmpty
    }

    /// Starts a test on `id` and returns the key to test, or nil when Test connection is off.
    public mutating func beginTest(_ id: String, keys: ProviderKeys) -> String? {
        guard canTest(id, keys: keys) else { return nil }
        testing = id
        return text(id, keys: keys).trimmingWhitespace()
    }

    /// Takes in a test's result. A pass on the key the field still holds returns the keys with it stored, for the caller
    /// to save; the enabled set doesn't change. A key edited during the test makes the result stale, and it is dropped.
    public mutating func finishTest(_ id: String, key: String, result: ProviderKeyCheck.Result, keys: ProviderKeys) -> ProviderKeys? {
        if testing == id { testing = nil }
        guard text(id, keys: keys).trimmingWhitespace() == key else { return nil }
        tested[id] = Tested(key: key, result: result)
        guard result.passed else { return nil }
        drafts[id] = nil
        return keys.setting(key, for: id)
    }

    /// Enable is available once a test passed on the key stored for `id`, while the provider is off.
    public func canEnable(_ id: String, keys: ProviderKeys) -> Bool {
        guard let stored = keys.keys[id], !keys.isEnabled(id), drafts[id] == nil, let tested = tested[id] else { return false }
        return tested.key == stored && tested.result.passed
    }

    /// Remove Key: the field empties and its result goes. Returns the keys without it, for the caller to save; the
    /// enabled set doesn't change, and with no key the provider is off.
    public mutating func removeKey(_ id: String, keys: ProviderKeys) -> ProviderKeys {
        drafts[id] = nil
        tested[id] = nil
        return keys.setting("", for: id)
    }
}
