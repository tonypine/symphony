import Foundation

/// Who started an update, which decides how it drains, what it says when it fails and what it records.
public enum UpdateKind: Equatable {
    /// Update to vX or Retry vX, chosen in the menu.
    case manual
    /// Automatically when idle or at a set time: the drain gives up once dispatch is paused and agent runs are still
    /// active after `runsTimeout`; 0 gives up as soon as a run is active.
    case automatic(runsTimeout: TimeInterval)
    /// Automatically when released: drains as Update to vX does, waiting for agent runs without giving up, and
    /// offers Update Now Anyway after the restart timeout.
    case onRelease

    /// How the drain waits for agent runs.
    public var drainPurpose: RestartMachine.Purpose {
        if case .automatic = self { return .automaticUpdate }
        return .update
    }

    /// How long the drain waits for agent runs before it gives up, or before it offers Update Now Anyway.
    public func runsTimeout(restartTimeout: TimeInterval) -> TimeInterval {
        if case let .automatic(runsTimeout) = self { return runsTimeout }
        return restartTimeout
    }

    /// The app started it by itself: it asks nothing, its failures show in the menu only, and the relaunched app
    /// posts "Symphony updated to vX" once the update is healthy.
    public var isAutomatic: Bool { self != .manual }

    /// Posts "Updating Symphony to vX" once it pauses dispatch (S4c), and Cancel Update holds its release (AU1).
    public var announcesStart: Bool { self == .onRelease }

    /// The line under the update items after a failure before the swap. Automatically when released tries again at
    /// the next check (S2f).
    public func failureLine(_ reason: String) -> String {
        let line = "\(UpdateMenu.failedTitle): \(reason)"
        guard self == .onRelease else { return line }
        let ended = line.hasSuffix(".") ? String(line.dropLast()) : line
        return ended + ". Trying again at the next check."
    }

    /// What the app records just before it quits for the update.
    public func pendingUpdate(
        _ release: Release,
        fromBuild: Int,
        startSymphony: Bool,
        resumeDispatch: Bool
    ) -> PendingUpdate {
        PendingUpdate(
            fromBuild: fromBuild,
            toBuild: release.build,
            version: release.version,
            startSymphony: startSymphony,
            resumeDispatch: resumeDispatch,
            details: ReleaseDetails(release),
            automatic: isAutomatic
        )
    }
}

/// When the notification that an on-release update has started (S4c) is posted and withdrawn. It is due once per
/// update: when the drain knows how many agent runs it waits for, or when it stops Symphony without waiting for any.
public struct UpdateStartNotifier: Equatable {
    public enum Effect: Equatable {
        case post(UpdateNotice)
        /// Remove the posted notification from Notification Center.
        case withdraw
    }

    /// The notification's request identifier, which removes it from Notification Center, from a relaunched app too.
    public static let requestIdentifier = "symphony.update.started"

    /// The version the update under way installs, until its notification is posted; nil when none is due.
    private var due: String?
    /// True while the notification shows, until the update ends.
    public private(set) var isPosted = false

    public init() {}

    /// An update started. Only one Automatically when released started announces itself.
    public mutating func began(_ release: Release, kind: UpdateKind) {
        due = kind.announcesStart ? release.version : nil
    }

    /// The drain moved to `phase`.
    public mutating func drained(_ phase: RestartMachine.Phase) -> Effect? {
        guard let version = due else { return nil }
        let runs: Int
        switch phase {
        case let .waitingForRuns(running: count?):
            runs = count
        case .stopping:
            runs = 0
        default:
            return nil
        }
        due = nil
        isPosted = true
        return .post(.updateStarted(version: version, activeRuns: runs))
    }

    /// The update ended, failed or was cancelled.
    public mutating func ended() -> Effect? {
        due = nil
        guard isPosted else { return nil }
        isPosted = false
        return .withdraw
    }
}

/// What Cancel Update does, chosen in the menu or on the update's start notification: the same either way.
public struct UpdateCancel: Equatable {
    public enum Step: Equatable {
        /// Stop the download and verification.
        case download
        /// Stop waiting for agent runs, resuming the dispatch the update paused.
        case drain
    }

    public var step: Step
    /// The release Automatically when released was installing, which `AutoUpdater.hold` holds (AU1); nil for the
    /// other kinds.
    public var hold: Release?

    /// Nil when there is nothing to call off: no update is under way, or it reached the swap (Symphony is
    /// stopping). `downloading` is whether the release is still downloading or being verified, `drain` the update's
    /// drain, and `release` the release it installs.
    public init?(downloading: Bool, drain: RestartMachine, kind: UpdateKind, release: Release?) {
        if downloading {
            step = .download
        } else if drain.purpose.isUpdate, drain.canCancel {
            step = .drain
        } else {
            return nil
        }
        hold = kind == .onRelease ? release : nil
    }
}
