import Foundation

/// SU12 and the end of SU11: what the app does once Symphony has started and checked its setup. The first time on this
/// Mac (no run recorded yet, as on a new Mac with a copied `symphony.yml`), setup errors open the Symphony window on
/// the Setup page with a welcome line. A repo Add Repo saved while Symphony was stopped opens Setup too when it, or the
/// global setup, has an error. A later launch with errors opens nothing: the badge and the menu bar say so.
public enum SetupOnStart {
    /// Shown above the Setup page when it opens on the first launch.
    public static let welcome = "Welcome to Symphony on this Mac. Before it takes tickets, fix the errors below: each one says what breaks, and its button shows the change before making it."

    public struct Decision: Equatable {
        /// Opens the Symphony window on the Setup page.
        public var openSetup: Bool
        /// With the welcome line: the first launch.
        public var welcome: Bool

        public init(openSetup: Bool, welcome: Bool = false) {
            self.openSetup = openSetup
            self.welcome = welcome
        }
    }

    /// What to do now, nil while there is nothing to decide: nothing is pending, Symphony isn't answering, or its first
    /// checks haven't finished. A decision settles everything pending, so the store is cleared after it.
    public static func decide(firstRunRecorded: Bool, pendingRepos: [String], status: SymphonyStatus) -> Decision? {
        guard !firstRunRecorded || !pendingRepos.isEmpty else { return nil }
        let snapshot: StateSnapshot
        switch status {
        case let .running(running, _), let .paused(running, _):
            snapshot = running
        case .stopped, .starting, .error:
            return nil
        }
        // A Symphony that predates Setup has nothing to show.
        guard let setup = snapshot.setup else { return Decision(openSetup: false) }
        guard setup.checkedAt != nil else { return nil }
        let firstRun = !firstRunRecorded && !setup.errors.isEmpty
        let repoErrors = pendingRepos.contains { !setup.forRepo($0).errors.isEmpty }
        return Decision(openSetup: firstRun || repoErrors, welcome: firstRun)
    }
}

/// The app's record of what `SetupOnStart` waits on: whether Symphony has run and checked its setup on this Mac, and the
/// repos Add Repo saved while it was stopped. In the app's defaults, so a QA root starts without it.
public final class SetupOnStartStore {
    public static let firstRunKey = "setupFirstRunRecorded"
    public static let pendingReposKey = "setupPendingRepos"

    private let defaults: KeyValueStore

    public init(defaults: KeyValueStore = UserDefaults.standard) {
        self.defaults = defaults
    }

    public var firstRunRecorded: Bool {
        defaults.object(forKey: Self.firstRunKey) as? Bool == true
    }

    public var pendingRepos: [String] {
        defaults.object(forKey: Self.pendingReposKey) as? [String] ?? []
    }

    /// Add Repo saved `key` while Symphony was stopped: Setup opens at its start if the repo has an error.
    public func addPending(_ key: String) {
        guard !pendingRepos.contains(key) else { return }
        defaults.set(pendingRepos + [key], forKey: Self.pendingReposKey)
    }

    /// The decision for `status`, recording that it was made: the first run, and no repo pending any more.
    public func settle(status: SymphonyStatus) -> SetupOnStart.Decision? {
        guard let decision = SetupOnStart.decide(firstRunRecorded: firstRunRecorded, pendingRepos: pendingRepos, status: status) else {
            return nil
        }
        defaults.set(true, forKey: Self.firstRunKey)
        defaults.set(nil, forKey: Self.pendingReposKey)
        return decision
    }
}
