import Foundation

/// What the app records just before it quits for an update, so the relaunched app can bring Symphony back.
public struct PendingUpdate: Equatable {
    /// The build that quit.
    public var fromBuild: Int
    /// The build it handed over to.
    public var toBuild: Int
    /// For example `0.0.1.42`.
    public var version: String
    /// Symphony was stopped for the update, so the relaunched app starts it.
    public var startSymphony: Bool
    /// The update paused dispatch, so the relaunched app resumes it once Symphony answers.
    public var resumeDispatch: Bool

    public init(fromBuild: Int, toBuild: Int, version: String, startSymphony: Bool, resumeDispatch: Bool) {
        self.fromBuild = fromBuild
        self.toBuild = toBuild
        self.version = version
        self.startSymphony = startSymphony
        self.resumeDispatch = resumeDispatch
    }

    /// False when the relaunched app is still the old build: the helper put it back.
    public func succeeded(runningBuild: Int) -> Bool {
        runningBuild >= toBuild
    }
}

/// Keeps the `PendingUpdate` in UserDefaults across the relaunch. It is read once, then forgotten.
public final class PendingUpdateStore {
    public static let key = "pendingUpdate"

    private let defaults: KeyValueStore

    public init(defaults: KeyValueStore = UserDefaults.standard) {
        self.defaults = defaults
    }

    public func save(_ pending: PendingUpdate) {
        defaults.set(
            [
                "fromBuild": pending.fromBuild,
                "toBuild": pending.toBuild,
                "version": pending.version,
                "startSymphony": pending.startSymphony,
                "resumeDispatch": pending.resumeDispatch,
            ] as [String: Any],
            forKey: Self.key
        )
    }

    public func clear() {
        defaults.set(nil, forKey: Self.key)
    }

    /// The pending update, cleared so a later launch doesn't act on it again. Nil when there is none or it
    /// can't be read.
    public func take() -> PendingUpdate? {
        guard let stored = defaults.object(forKey: Self.key) else { return nil }
        clear()
        guard let values = stored as? [String: Any],
            let fromBuild = values["fromBuild"] as? Int,
            let toBuild = values["toBuild"] as? Int,
            let version = values["version"] as? String,
            let startSymphony = values["startSymphony"] as? Bool,
            let resumeDispatch = values["resumeDispatch"] as? Bool
        else { return nil }
        return PendingUpdate(
            fromBuild: fromBuild,
            toBuild: toBuild,
            version: version,
            startSymphony: startSymphony,
            resumeDispatch: resumeDispatch
        )
    }
}

/// Whether this app can update itself.
public enum UpdateEligibility {
    /// Why Update is off, nil when it is available.
    public static func blocker(
        build: AppBuild,
        developmentMode: Bool,
        hasPublicKey: Bool,
        appLocationWritable: Bool
    ) -> String? {
        if build.isDevelopment { return "Updates need a release build of Symphony.app" }
        if developmentMode { return "Updates are off in Development mode" }
        if !hasPublicKey { return "This build has no update signing key" }
        if !appLocationWritable { return "Move Symphony.app to a folder you can write to, such as ~/Applications" }
        return nil
    }
}

/// The script that swaps the app once it has quit: `Contents/Resources/update-helper.sh`.
public enum UpdateHelper {
    public static let resourceName = "update-helper.sh"
    public static let logName = "update-helper.log"
    /// The Info.plist key that holds the minisign public key releases are checked against.
    public static let publicKeyInfoKey = "SymphonyUpdatePublicKey"

    /// Where the replaced app is kept for a manual rollback: next to the app, as `Symphony (previous).app`.
    public static func previousAppURL(for app: URL) -> URL {
        app.deletingLastPathComponent().appendingPathComponent("Symphony (previous).app", isDirectory: true)
    }

    /// `sh <script> <pid> <current app> <new app> <previous app>`.
    public static func arguments(script: URL, pid: Int32, currentApp: URL, newApp: URL) -> [String] {
        [script.path, String(pid), currentApp.path, newApp.path, previousAppURL(for: currentApp).path]
    }
}
