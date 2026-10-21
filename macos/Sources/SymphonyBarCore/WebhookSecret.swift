import Foundation

/// The secret GitHub signs instant updates with (`SymphonyElixir.GitHub.WebhookSecret`). Symphony makes it and hands
/// it off in a file only the user can read, `<state root>/github_webhook_secret`; the app moves it into its secret item
/// `symphony-github-webhook` and passes it to Symphony as `SYMPHONY_GITHUB_WEBHOOK_SECRET` from then on. The value is
/// never shown, logged or kept anywhere else: what a move answers says only whether it worked.
public enum WebhookSecret {
    /// The app's secret item that keeps it.
    public static let item = "symphony-github-webhook"
    /// The variable the launcher passes it in, and the one `symphony.yml` names.
    public static let environmentKey = "SYMPHONY_GITHUB_WEBHOOK_SECRET"
    /// The file Symphony hands it off in, under its state root.
    public static let handOffFileName = "github_webhook_secret"

    /// What moving the hand-off did.
    public enum Move: Equatable {
        /// The secret is in the app's secret item, and the hand-off file is gone.
        case saved
        /// Symphony handed nothing off: there is no file, or it is empty.
        case nothingHandedOff
        /// The secret item couldn't be written, in plain words; the hand-off file stays, so Symphony still reads it.
        case failed(String)
    }

    /// Where Symphony hands the secret off for a state root.
    public static func handOffFile(stateRoot: URL) -> URL {
        stateRoot.appendingPathComponent(handOffFileName)
    }

    /// Moves the secret handed off at `file` into `store`, then deletes the file. A file that can't be deleted stays:
    /// Symphony reads the variable before it, so the move still counts.
    public static func moveHandOff(from file: URL, into store: SecretStore, fileManager: FileManager = .default) -> Move {
        guard let data = fileManager.contents(atPath: file.path) else { return .nothingHandedOff }
        let value = String(decoding: data, as: UTF8.self).trimmingWhitespace()
        guard !value.isEmpty else { return .nothingHandedOff }
        do {
            try store.setValue(value, forAccount: item)
        } catch {
            // The store's errors name its file or Keychain status, never the value.
            return .failed("Couldn't save the webhook secret in your Keychain: \(error.localizedDescription)")
        }
        try? fileManager.removeItem(at: file)
        return .saved
    }

    /// True when the app's secret item holds a secret.
    public static func isStored(in store: SecretStore) -> Bool {
        guard let value = try? store.value(forAccount: item) else { return false }
        return !value.isEmpty
    }
}
