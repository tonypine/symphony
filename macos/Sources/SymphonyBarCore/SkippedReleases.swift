import Foundation

/// A release build the app doesn't offer as available: one you chose Skip This Version for, or one an update
/// rolled back.
public struct SkippedRelease: Equatable {
    public enum Reason: String {
        case skipped
        case rolledBack = "rolled back"
    }

    public var build: Int
    /// For example `0.0.1.42`.
    public var version: String
    public var reason: Reason

    public init(build: Int, version: String, reason: Reason) {
        self.build = build
        self.version = version
        self.reason = reason
    }

    public init(_ release: Release, reason: Reason) {
        self.init(build: release.build, version: release.version, reason: reason)
    }
}

/// The skipped builds, kept in UserDefaults across relaunches. A skip covers one build only, so a newer release
/// is offered as usual.
public final class SkippedReleaseStore {
    public static let key = "skippedReleases"

    private let defaults: KeyValueStore

    public init(defaults: KeyValueStore = UserDefaults.standard) {
        self.defaults = defaults
    }

    /// Records the build, replacing what was recorded for it.
    public func record(_ skipped: SkippedRelease) {
        var stored = storedEntries
        stored[String(skipped.build)] = ["version": skipped.version, "reason": skipped.reason.rawValue]
        defaults.set(stored, forKey: Self.key)
    }

    /// What was recorded for `build`, nil when it isn't skipped or the entry can't be read.
    public func entry(forBuild build: Int) -> SkippedRelease? {
        guard let values = storedEntries[String(build)] as? [String: Any],
            let version = values["version"] as? String,
            let reason = (values["reason"] as? String).flatMap(SkippedRelease.Reason.init(rawValue:))
        else { return nil }
        return SkippedRelease(build: build, version: version, reason: reason)
    }

    /// Forgets the skip for `build`, as when you install it by hand.
    public func clear(build: Int) {
        var stored = storedEntries
        guard stored.removeValue(forKey: String(build)) != nil else { return }
        defaults.set(stored.isEmpty ? nil : stored, forKey: Self.key)
    }

    private var storedEntries: [String: Any] {
        defaults.object(forKey: Self.key) as? [String: Any] ?? [:]
    }
}

/// A release newer than the running build, as the menu shows it.
public enum UpdateOffer: Equatable {
    case available(Release)
    case skipped(Release, SkippedRelease.Reason)

    /// `release` as skipped when `store` records its build, otherwise as available.
    public init(_ release: Release, skips store: SkippedReleaseStore) {
        if let skipped = store.entry(forBuild: release.build) {
            self = .skipped(release, skipped.reason)
        } else {
            self = .available(release)
        }
    }

    public var release: Release {
        switch self {
        case let .available(release), let .skipped(release, _):
            return release
        }
    }

    /// The install item: "Retry vX" for a release an update rolled back, otherwise "Update to vX".
    public var installTitle: String {
        if case let .skipped(release, .rolledBack) = self { return UpdateMenu.retryTitle(release) }
        return UpdateMenu.installTitle(release)
    }

    /// True while Skip This Version shows: the release is available and not skipped yet.
    public var offersSkip: Bool {
        if case .available = self { return true }
        return false
    }

    /// The menu's line for the release, for example "Update available: v0.0.1.42 (12 changes)".
    public func title(current: AppBuild) -> String {
        switch self {
        case let .available(release):
            return UpdateMenu.availableTitle(release, current: current)
        case let .skipped(release, reason):
            return UpdateMenu.skippedTitle(release, reason: reason, current: current)
        }
    }
}
