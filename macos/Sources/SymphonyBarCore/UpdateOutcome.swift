import Foundation

/// The update the running build came from, once it passed its health check: the menu says what changed until the next
/// update, or for `shownFor`.
public struct LastUpdate: Equatable {
    /// How long the menu line shows after the update.
    public static let shownFor: TimeInterval = 7 * 24 * 60 * 60

    /// For example `0.0.1.43`.
    public var version: String
    public var build: Int
    public var details: ReleaseDetails
    public var installedAt: Date

    public init(version: String, build: Int, details: ReleaseDetails, installedAt: Date) {
        self.version = version
        self.build = build
        self.details = details
        self.installedAt = installedAt
    }

    /// The healthy update `pending` describes.
    public init(_ pending: PendingUpdate, installedAt: Date) {
        self.init(version: pending.version, build: pending.toBuild, details: pending.details, installedAt: installedAt)
    }

    /// True while the app still runs this build and `shownFor` hasn't passed. A later update, or a rollback, runs
    /// another build.
    public func isShown(runningBuild: Int, now: Date) -> Bool {
        runningBuild == build && now.timeIntervalSince(installedAt) < Self.shownFor
    }
}

/// Keeps the `LastUpdate` in UserDefaults, read at each menu refresh until the next update replaces it.
public final class LastUpdateStore {
    public static let key = "lastUpdate"

    private let defaults: KeyValueStore

    public init(defaults: KeyValueStore = UserDefaults.standard) {
        self.defaults = defaults
    }

    public func save(_ update: LastUpdate) {
        let values: [String: Any] = [
            "version": update.version,
            "build": update.build,
            "installedAt": update.installedAt.timeIntervalSince1970,
        ]
        defaults.set(values.merging(update.details.storedValues) { first, _ in first }, forKey: Self.key)
    }

    public func clear() {
        defaults.set(nil, forKey: Self.key)
    }

    /// The last update, nil when there is none or it can't be read.
    public func load() -> LastUpdate? {
        guard let values = defaults.object(forKey: Self.key) as? [String: Any],
            let version = values["version"] as? String,
            let build = values["build"] as? Int,
            let installedAt = values["installedAt"] as? TimeInterval
        else { return nil }
        return LastUpdate(
            version: version,
            build: build,
            details: ReleaseDetails(stored: values),
            installedAt: Date(timeIntervalSince1970: installedAt)
        )
    }

    /// The last update while its menu line shows.
    public func shown(runningBuild: Int, now: Date = Date()) -> LastUpdate? {
        load().flatMap { $0.isShown(runningBuild: runningBuild, now: now) ? $0 : nil }
    }
}

/// The menu line about the last update or rollback, which opens the release notes of the version it names.
public enum UpdateOutcome: Equatable {
    /// "Updated to vX (N changes)".
    case updated(LastUpdate)
    /// "vX was rolled back: …", from the build a health check put back.
    case rolledBack(RollbackRecord)

    /// A rollback this session comes first; otherwise the last update while it shows.
    public init?(rolledBack: RollbackRecord?, lastUpdate: LastUpdate?) {
        if let rolledBack {
            self = .rolledBack(rolledBack)
        } else if let lastUpdate {
            self = .updated(lastUpdate)
        } else {
            return nil
        }
    }

    public var menuTitle: String {
        switch self {
        case let .updated(update):
            return UpdateMenu.updatedLine(update)
        case let .rolledBack(record):
            return UpdateMenu.rolledBackLine(record)
        }
    }

    /// The release whose notes the line opens. A record from a build that didn't keep the release's page falls back
    /// to `latest`, the release the last update check found, when it is the same build. Nil leaves the line disabled.
    public func release(latest: Release?) -> Release? {
        let (version, build, details) = parts
        return details.release(version: version, build: build) ?? (latest?.build == build ? latest : nil)
    }

    /// The text above the notes, nil for none: after a rollback, what failed and where the manual steps are.
    public var notesMessage: String? {
        switch self {
        case .updated:
            return nil
        case let .rolledBack(record):
            return UpdateMenu.rolledBackNotesMessage(record)
        }
    }

    private var parts: (String, Int, ReleaseDetails) {
        switch self {
        case let .updated(update):
            return (update.version, update.build, update.details)
        case let .rolledBack(record):
            return (record.version, record.build, record.details)
        }
    }
}

/// The notification the app posts after an update or a rollback.
public struct UpdateNotice: Equatable {
    public var title: String
    public var body: String

    public init(title: String, body: String) {
        self.title = title
        self.body = body
    }

    /// After an automatic update passed its health check. A manual update you just confirmed gets none.
    public static func updated(_ update: LastUpdate) -> UpdateNotice {
        let changes = update.details.changes.map { "\(UpdateMenu.changeCount($0)). " } ?? ""
        return UpdateNotice(
            title: "Symphony updated to v\(update.version)",
            body: changes + "Choose Updated to v\(update.version) in the menu for the release notes."
        )
    }

    /// Posted by the build a health check put back, `restoredVersion` being its own version when known.
    public static func rolledBack(_ record: RollbackRecord, restoredVersion: String?) -> UpdateNotice {
        UpdateNotice(
            title: restoredVersion.map { "Symphony rolled back to v\($0)" } ?? "Symphony rolled back v\(record.version)",
            body: "v\(record.version) failed its health check (\(record.reason)). It won't be installed by itself "
                + "again; choose \(UpdateMenu.retryTitle(version: record.version)) in the menu to install it."
        )
    }

    /// A version failed its health check but couldn't be rolled back.
    public static func rollbackFailed(version: String, reason: String, problem: RollbackProblem) -> UpdateNotice {
        UpdateNotice(
            title: "Symphony couldn't roll back v\(version)",
            body: UpdateMenu.rollbackFailedLine(version: version, reason: reason, problem: problem)
        )
    }
}
