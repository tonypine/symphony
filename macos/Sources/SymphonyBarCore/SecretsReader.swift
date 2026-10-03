import Foundation

/// Reads the secrets on a background queue, so a Keychain password prompt can't freeze the menu, and says
/// whether a read is still waiting so the menu can show it. Use it from `callbackQueue` only.
public final class SecretsReader {
    /// Called on `callbackQueue` when a read starts or ends.
    public var onChange: (() -> Void)?

    /// Reads started and not yet finished.
    public private(set) var pendingReads = 0

    /// True while a read waits, which is usually a Keychain prompt waiting for the user.
    public var isWaiting: Bool { pendingReads > 0 }

    private let load: () throws -> SecretSettings
    private let queue: DispatchQueue
    private let callbackQueue: DispatchQueue

    /// Reads one at a time on `queue`, so two reads can't put up two prompts, and reports on `callbackQueue`.
    public init(
        queue: DispatchQueue = DispatchQueue(label: "com.tonypine.symphony.bar.secrets"),
        callbackQueue: DispatchQueue = .main,
        load: @escaping () throws -> SecretSettings
    ) {
        self.queue = queue
        self.callbackQueue = callbackQueue
        self.load = load
    }

    /// Starts a read; `completion` gets the secrets or the Keychain error on `callbackQueue`.
    public func read(_ completion: @escaping (Result<SecretSettings, Error>) -> Void) {
        pendingReads += 1
        onChange?()
        let load = load
        let callbackQueue = callbackQueue
        queue.async {
            let result = Result { try load() }
            callbackQueue.async {
                self.pendingReads -= 1
                self.onChange?()
                completion(result)
            }
        }
    }
}
