import Foundation

/// What the menu shows of a release once the app runs it: its notes and page, and its change count. The relaunched
/// build is the latest release, so no update check offers them any more.
public struct ReleaseDetails: Equatable {
    public var notes: String
    /// Nil when the record was written by a build that didn't keep it.
    public var pageURL: URL?
    public var changes: Int?

    public init(notes: String = "", pageURL: URL? = nil, changes: Int? = nil) {
        self.notes = notes
        self.pageURL = pageURL
        self.changes = changes
    }

    public init(_ release: Release) {
        self.init(notes: release.notes, pageURL: release.pageURL, changes: release.changes)
    }

    /// The release for the notes window, nil without a page URL.
    public func release(version: String, build: Int) -> Release? {
        pageURL.map { Release(version: version, build: build, notes: notes, pageURL: $0, changes: changes) }
    }

    /// The keys a store adds to its record.
    var storedValues: [String: Any] {
        var values: [String: Any] = ["notes": notes]
        if let pageURL { values["pageURL"] = pageURL.absoluteString }
        if let changes { values["changes"] = changes }
        return values
    }

    /// Reads `storedValues`; a missing key, as from an older build, reads as unknown.
    init(stored values: [String: Any]) {
        self.init(
            notes: values["notes"] as? String ?? "",
            pageURL: (values["pageURL"] as? String).flatMap(URL.init(string:)),
            changes: values["changes"] as? Int
        )
    }
}

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
    /// The release's notes, page and change count, for the menu line after the update.
    public var details: ReleaseDetails
    /// The app installed it by itself, so the relaunched app posts a notification once it is healthy.
    public var automatic: Bool

    public init(
        fromBuild: Int,
        toBuild: Int,
        version: String,
        startSymphony: Bool,
        resumeDispatch: Bool,
        details: ReleaseDetails = ReleaseDetails(),
        automatic: Bool = false
    ) {
        self.fromBuild = fromBuild
        self.toBuild = toBuild
        self.version = version
        self.startSymphony = startSymphony
        self.resumeDispatch = resumeDispatch
        self.details = details
        self.automatic = automatic
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
        let values: [String: Any] = [
            "fromBuild": pending.fromBuild,
            "toBuild": pending.toBuild,
            "version": pending.version,
            "startSymphony": pending.startSymphony,
            "resumeDispatch": pending.resumeDispatch,
            "automatic": pending.automatic,
        ]
        defaults.set(values.merging(pending.details.storedValues) { first, _ in first }, forKey: Self.key)
    }

    public func clear() {
        defaults.set(nil, forKey: Self.key)
    }

    /// The pending update, cleared so a later launch doesn't act on it again. Nil when there is none or it
    /// can't be read. One from a build that didn't record the release's details or `automatic` reads them as unknown
    /// and false.
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
            resumeDispatch: resumeDispatch,
            details: ReleaseDetails(stored: values),
            automatic: values["automatic"] as? Bool ?? false
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
    /// The helper's log when it rolls an update back.
    public static let rollbackLogName = "rollback-helper.log"
    /// The helper's PATH outside QA mode: the system tools it runs.
    public static let path = "/usr/bin:/bin:/usr/sbin:/sbin"
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

    /// Where a rollback moves the build that failed its health check: next to the app, as
    /// `Symphony (rolled back).app`, out of the previous app's place.
    public static func rolledBackAppURL(for app: URL) -> URL {
        app.deletingLastPathComponent().appendingPathComponent("Symphony (rolled back).app", isDirectory: true)
    }

    /// The same swap reversed: `sh <script> <pid> <current app> <previous app> <rolled back app>` moves the running
    /// app aside as `Symphony (rolled back).app` and the previous app into its place, then relaunches it.
    public static func rollbackArguments(script: URL, pid: Int32, currentApp: URL) -> [String] {
        [
            script.path, String(pid), currentApp.path, previousAppURL(for: currentApp).path,
            rolledBackAppURL(for: currentApp).path,
        ]
    }
}
