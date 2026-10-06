import Foundation

/// Why an updated build failed its health check.
public enum UpdateHealthFailure: Equatable {
    /// `symphony check` with the new embedded binary failed; the message says why.
    case configCheck(String)
    /// The started Symphony didn't answer on its control URL within `UpdateHealthCheck.answerTimeout`.
    case noAnswer
    /// Symphony exited unexpectedly `UpdateHealthCheck.crashLimit` times within `UpdateHealthCheck.crashWindow`.
    case crashLoop

    /// What failed, for the menu line of the build that is put back. `logPath` is Symphony's log.
    public func reason(logPath: String) -> String {
        switch self {
        case let .configCheck(message):
            return "symphony check failed: \(message)"
        case .noAnswer:
            return "Symphony didn't answer within \(Int(UpdateHealthCheck.answerTimeout)) seconds of starting; "
                + "see \(logPath)"
        case .crashLoop:
            return "Symphony stopped unexpectedly \(UpdateHealthCheck.crashLimit) times within "
                + "\(Int(UpdateHealthCheck.crashWindow / 60)) minutes; see \(logPath)"
        }
    }
}

/// Checks that Symphony is healthy on the build an update relaunched, kept free of AppKit so it can be unit tested
/// with an injected clock. Events go in; the effects the app must carry out come back.
///
/// 1. `symphony check` with the new embedded binary must pass.
/// 2. When the app starts Symphony after the update, it must answer within `answerTimeout` of starting.
/// 3. Until `crashWindow` after the update, an unexpected exit starts Symphony again, so a crash loop can be counted;
///    the `crashLimit`th one fails. After the window an exit is left alone, as outside an update.
///
/// Once the config check passed and Symphony answered (or the app doesn't start it), the update counts as healthy: the
/// app records it and says so, once. A crash loop in the window after that still rolls it back. A failure asks the app
/// to roll back. When the app doesn't start Symphony, only the config check runs.
public struct UpdateHealthCheck: Equatable {
    public static let answerTimeout = RestartMachine.answerTimeout
    public static let crashWindow: TimeInterval = 10 * 60
    public static let crashLimit = 3

    public enum Phase: Equatable {
        /// No check began.
        case idle
        case checkingConfig
        /// The config check passed and the app starts Symphony.
        case starting
        /// Symphony was started and hasn't answered yet.
        case waitingForAnswer
        /// Symphony answered, or isn't running because it was stopped: counting unexpected exits until the window
        /// ends.
        case watching
        case passed
        case failed(UpdateHealthFailure)
    }

    public enum Event: Equatable {
        case configChecked(ConfigCheckResult)
        /// The app started Symphony.
        case started
        /// The app didn't start Symphony: one already runs outside the app, or Start failed.
        case notStarted
        case polled(StatusPoll)
        /// The app's Symphony exited; `requested` is true when the app or you stopped it.
        case exited(requested: Bool)
    }

    public enum Effect: Equatable {
        /// Run `symphony check --config <symphony.yml>` with the new build's Symphony, as Start would run it.
        case checkConfig
        /// Start Symphony, then report `.started` or `.notStarted`.
        case start
        /// Symphony works on the new build: record the update and say so. Comes once per check.
        case healthy
        /// Put the previous build back.
        case rollBack(UpdateHealthFailure)
    }

    public private(set) var phase: Phase = .idle
    /// The updated version, for example `0.0.1.43`.
    public private(set) var version = ""
    public private(set) var unexpectedExits = 0

    private var startsSymphony = false
    private var reportedHealthy = false
    private var windowEnd = Date.distantPast
    private var answerDeadline = Date.distantPast

    public init() {}

    /// True until Symphony has answered (or the check needs no answer): the app holds automatic updates meanwhile.
    public var isChecking: Bool {
        switch phase {
        case .checkingConfig, .starting, .waitingForAnswer:
            return true
        case .idle, .watching, .passed, .failed:
            return false
        }
    }

    /// True while the check can still fail, so an unexpected exit is counted and Symphony started again.
    public var isActive: Bool {
        isChecking || phase == .watching
    }

    /// Starts the check on the relaunched build. `startsSymphony` is whether the app starts Symphony after the update.
    public mutating func begin(version: String, startsSymphony: Bool, now: Date = Date()) -> [Effect] {
        guard phase == .idle else { return [] }
        self.version = version
        self.startsSymphony = startsSymphony
        windowEnd = now.addingTimeInterval(Self.crashWindow)
        phase = .checkingConfig
        return [.checkConfig]
    }

    public mutating func handle(_ event: Event, now: Date = Date()) -> [Effect] {
        switch (phase, event) {
        case let (.checkingConfig, .configChecked(.failed(message))):
            return fail(.configCheck(message))

        case (.checkingConfig, .configChecked(.passed)):
            guard startsSymphony else {
                phase = .passed
                return healthy()
            }
            phase = .starting
            return [.start]

        case (.starting, .started):
            phase = .waitingForAnswer
            answerDeadline = now.addingTimeInterval(Self.answerTimeout)
            return []

        case (.starting, .notStarted), (.waitingForAnswer, .exited(requested: true)),
            (.waitingForAnswer, .polled(.state)):
            watch(now: now)
            return healthy()

        case (.waitingForAnswer, .polled):
            return now >= answerDeadline ? fail(.noAnswer) : []

        case (.watching, .polled):
            watch(now: now)
            return []

        case (.waitingForAnswer, .exited(requested: false)), (.watching, .exited(requested: false)):
            guard now < windowEnd else {
                phase = .passed
                return []
            }
            unexpectedExits += 1
            guard unexpectedExits < Self.crashLimit else { return fail(.crashLoop) }
            phase = .starting
            return [.start]

        default:
            return []
        }
    }

    /// The line under the update items while the check runs, nil otherwise.
    public var menuLine: String? {
        switch phase {
        case .checkingConfig:
            return "Checking v\(version): running symphony check…"
        case .starting, .waitingForAnswer:
            return "Checking v\(version): waiting for Symphony to answer…"
        case .idle, .watching, .passed, .failed:
            return nil
        }
    }

    private mutating func watch(now: Date) {
        phase = now >= windowEnd ? .passed : .watching
    }

    /// `.healthy` the first time the check stops holding, nothing after a restart in the window.
    private mutating func healthy() -> [Effect] {
        guard !reportedHealthy else { return [] }
        reportedHealthy = true
        return [.healthy]
    }

    private mutating func fail(_ failure: UpdateHealthFailure) -> [Effect] {
        phase = .failed(failure)
        return [.rollBack(failure)]
    }
}

/// What the build that failed its health check records just before the rollback swap, so the build put back can say
/// why and bring Symphony back as it was before the update.
public struct RollbackRecord: Equatable {
    /// The build that was rolled back.
    public var build: Int
    /// Its version, for example `0.0.1.43`.
    public var version: String
    /// What failed, from `UpdateHealthFailure.reason`.
    public var reason: String
    /// Symphony ran before the update, so the restored app starts it.
    public var startSymphony: Bool
    /// The update paused dispatch, so the restored app resumes it once Symphony answers.
    public var resumeDispatch: Bool
    /// The rolled-back release's notes, page and change count, which its menu line opens.
    public var details: ReleaseDetails
    /// The file number of the failed build's app bundle, from `bundleFileNumber(_:)`; nil when it couldn't be read or
    /// the record comes from a version from before it was kept.
    public var bundle: Int?

    public init(
        build: Int,
        version: String,
        reason: String,
        startSymphony: Bool,
        resumeDispatch: Bool,
        details: ReleaseDetails = ReleaseDetails(),
        bundle: Int? = nil
    ) {
        self.build = build
        self.version = version
        self.reason = reason
        self.startSymphony = startSymphony
        self.resumeDispatch = resumeDispatch
        self.details = details
        self.bundle = bundle
    }

    /// False when the relaunched app is still the build that failed: the swap didn't happen.
    public func succeeded(runningBuild: Int) -> Bool {
        runningBuild < build
    }

    /// False when the failed build was installed again since: the helper only renames app bundles, so a failed swap
    /// relaunches the bundle that recorded this, while a reinstall puts a new one in its place. True when either
    /// number is unknown.
    public func isSameBundle(_ runningBundle: Int?) -> Bool {
        guard let bundle, let runningBundle else { return true }
        return bundle == runningBundle
    }

    /// The file number of the app bundle at `url`, nil when it can't be read. Renaming or moving the bundle in its
    /// folder keeps it; installing the app again gives it a new one.
    public static func bundleFileNumber(_ url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.systemFileNumber] as? Int
    }
}

/// Keeps the `RollbackRecord` in UserDefaults across the relaunch. It is read once, then forgotten.
public final class RollbackStore {
    public static let key = "updateRollback"

    private let defaults: KeyValueStore

    public init(defaults: KeyValueStore = UserDefaults.standard) {
        self.defaults = defaults
    }

    public func save(_ record: RollbackRecord) {
        var values: [String: Any] = [
            "build": record.build,
            "version": record.version,
            "reason": record.reason,
            "startSymphony": record.startSymphony,
            "resumeDispatch": record.resumeDispatch,
        ]
        values["bundle"] = record.bundle
        defaults.set(values.merging(record.details.storedValues) { first, _ in first }, forKey: Self.key)
    }

    public func clear() {
        defaults.set(nil, forKey: Self.key)
    }

    /// The record, cleared so a later launch doesn't act on it again. Nil when there is none or it can't be read.
    public func take() -> RollbackRecord? {
        guard let stored = defaults.object(forKey: Self.key) else { return nil }
        clear()
        guard let values = stored as? [String: Any],
            let build = values["build"] as? Int,
            let version = values["version"] as? String,
            let reason = values["reason"] as? String,
            let startSymphony = values["startSymphony"] as? Bool,
            let resumeDispatch = values["resumeDispatch"] as? Bool
        else { return nil }
        return RollbackRecord(
            build: build,
            version: version,
            reason: reason,
            startSymphony: startSymphony,
            resumeDispatch: resumeDispatch,
            details: ReleaseDetails(stored: values),
            bundle: values["bundle"] as? Int
        )
    }
}

/// What the app does at launch after an update or a rollback, from what the quitting app recorded.
public enum UpdateRelaunch: Equatable {
    /// A normal launch.
    case none
    /// The helper couldn't swap the new app in, so this is still the old build.
    case notReplaced(PendingUpdate)
    /// This is the updated build: check that Symphony is healthy on it.
    case checkHealth(PendingUpdate)
    /// A health check rolled the update back and this is the build it put back. It never checks itself, so a
    /// rollback can't loop.
    case rolledBack(RollbackRecord)
    /// The rollback's swap failed, so this is still the build that failed its health check.
    case rollbackFailed(RollbackRecord)

    /// A failed build takes the pending update before it records its rollback, and the build it puts back is older,
    /// so any pending update, a build newer than the record, or the failed build in another app bundle means the
    /// record is stale: a version from before automatic rollback was put back, never read it, and has since started
    /// this update (to any build, the rolled-back one included), been replaced by a newer one, or been replaced by
    /// hand with the failed build. `runningBundle` is the running app's `RollbackRecord.bundleFileNumber`.
    public init(pending: PendingUpdate?, rollback: RollbackRecord?, runningBuild: Int, runningBundle: Int? = nil) {
        if let rollback, pending == nil, runningBuild < rollback.build
            || (runningBuild == rollback.build && rollback.isSameBundle(runningBundle))
        {
            self = rollback.succeeded(runningBuild: runningBuild) ? .rolledBack(rollback) : .rollbackFailed(rollback)
        } else if let pending {
            self = pending.succeeded(runningBuild: runningBuild) ? .checkHealth(pending) : .notReplaced(pending)
        } else {
            self = .none
        }
    }
}

/// Why a rollback didn't happen.
public enum RollbackProblem: Equatable {
    /// There is no `Symphony (previous).app` to put back.
    case noPreviousApp
    /// The helper couldn't start; the message says why.
    case helper(String)
    /// The helper ran but couldn't swap the apps; its log is at the path.
    case swapFailed(logPath: String)

    var detail: String {
        switch self {
        case .noPreviousApp:
            return "there is no Symphony (previous).app"
        case let .helper(message):
            return message
        case let .swapFailed(logPath):
            return "the apps couldn't be swapped; see \(logPath)"
        }
    }

    /// The manual steps of the README's Rollback section.
    var manualSteps: String {
        switch self {
        case .noPreviousApp:
            return "To go back, quit Symphony and reinstall the previous release with the install script "
                + "(SYMPHONY_RELEASE_TAG)."
        case .helper, .swapFailed:
            return "To roll back by hand, quit Symphony, rename Symphony.app to Symphony (rolled back).app and "
                + "Symphony (previous).app to Symphony.app, then open it."
        }
    }
}
