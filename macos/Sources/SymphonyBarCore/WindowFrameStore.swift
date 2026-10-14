import Foundation

/// A window's saved frame, as `NSWindow.frameDescriptor` writes it, in the app's key-value store: UserDefaults
/// normally, the QA root's settings in QA mode, so a QA pass never restores a frame another pass left. Uses the key
/// AppKit's frame autosave uses, so a frame saved before this store keeps coming back.
public final class WindowFrameStore {
    public let key: String
    private let defaults: KeyValueStore

    public init(name: String, defaults: KeyValueStore) {
        key = "NSWindow Frame \(name)"
        self.defaults = defaults
    }

    /// The saved frame descriptor, nil when there is none.
    public func load() -> String? {
        (defaults.object(forKey: key) as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    public func save(_ descriptor: String) {
        defaults.set(descriptor, forKey: key)
    }
}
