import Foundation

/// What a change made from the Repos window did: Add Repo, Edit, Disconnect or Remove Clone, or the write that failed.
public enum ReposChange: Equatable {
    /// `workflow` is the `WORKFLOW.md` the sheet added, nil when it added none.
    case added(key: String, apply: AddRepoApply, madeDefault: String?, workflow: PendingWorkflow? = nil)
    /// `apply` is nil when Symphony reads the change from `symphony.yml` without a restart.
    case edited(key: String, apply: AddRepoApply?)
    /// `next` is the repo selected in its place.
    case disconnected(key: String, apply: AddRepoApply, newDefault: String?, next: String?)
    case cloneRemoved(key: String, path: String)
    /// Symphony's clone wasn't deleted, because an agent uses it or it isn't in the clones folder.
    case cloneKept(key: String, reason: String)
    /// A write that failed, on the repo it was for; nil when it wasn't for one repo.
    case failed(key: String?, message: String)

    /// The banner the change shows on its repo.
    public var banner: ReposBanner {
        switch self {
        case let .added(key, apply, madeDefault, workflow):
            return ReposBanner(
                key: key,
                text: AddRepo.savedMessage(key: key, apply: apply, madeDefault: madeDefault, workflow: workflow)
            )
        case let .edited(key, apply):
            return ReposBanner(key: key, text: EditRepo.savedMessage(key: key, apply: apply))
        case let .disconnected(key, apply, newDefault, next):
            return ReposBanner(key: next, text: DisconnectRepo.message(key: key, apply: apply, newDefault: newDefault))
        case let .cloneRemoved(key, path):
            return ReposBanner(key: key, text: ManagedClones.removedMessage(key: key, path: path))
        case let .cloneKept(key, reason):
            return ReposBanner(key: key, text: "Didn't remove the clone: \(reason)", style: .error)
        case let .failed(key, message):
            return ReposBanner(key: key, text: message, style: .error)
        }
    }

    /// The banner once the restart question is answered with Later.
    public var laterBanner: ReposBanner {
        switch self {
        case let .added(key, _, _, _):
            return ReposBanner(key: key, text: "Added \(key). Restart Symphony from the menu to connect it.")
        case let .edited(key, _):
            return ReposBanner(key: key, text: "Saved \(key). Restart Symphony from the menu to apply it.")
        case let .disconnected(key, _, _, next):
            return ReposBanner(key: next, text: "Disconnected \(key). Restart Symphony from the menu to drop it.")
        case .cloneRemoved, .cloneKept, .failed:
            return banner
        }
    }
}

/// The banner at the top of a repo's detail saying what the last change did. It stays until dismissed or the next
/// change.
public struct ReposBanner: Equatable {
    public enum Style: Equatable {
        case info
        case error
    }

    /// The repo it sits on; nil sits on whichever repo is selected.
    public var key: String?
    public var text: String
    public var style: Style

    public init(key: String?, text: String, style: Style = .info) {
        self.key = key
        self.text = text
        self.style = style
    }

    public static let dismissTitle = "Dismiss"

    /// Whether the detail of `selection` shows the banner. A repo the window doesn't list, such as one just added
    /// while a running Symphony lists only the repos it started with, puts its banner on the repo shown instead, so
    /// a poll never hides it.
    public func isShown(on selection: String?, listed keys: [String]) -> Bool {
        guard let key, keys.contains(key) else { return true }
        return key == selection
    }
}

extension DisconnectRepo {
    /// The repo to select once `key` is disconnected: the one after it in `keys`, else the one before.
    public static func nextSelection(after key: String, in keys: [String]) -> String? {
        guard let index = keys.firstIndex(of: key) else { return keys.first }
        if index + 1 < keys.count { return keys[index + 1] }
        return index > 0 ? keys[index - 1] : nil
    }
}

/// The Repos window's toolbar chip while a graceful restart or an update's drain is under way, and its pop-over.
public struct ReposRestartChip: Equatable {
    public var title: String
    /// What the restart does now, as the menu says it.
    public var line: String?
    /// The agent runs it waits on, as "billing-api: TP-7".
    public var runs: [String]
    /// Restart Now shows while the restart waits for runs, and is on once the runs outlast the restart timeout.
    public var showsRestartNow: Bool
    public var restartNowEnabled: Bool
    /// Cancel Restart shows while the restart controller can cancel.
    public var showsCancel: Bool
    public var restartNowTitle: String
    public var cancelTitle: String

    public static let restartNowTitle = "Restart Now"
    public static let updateNowTitle = "Update Now"
    public static let restartNowHelp = "Offered once the runs outlast the restart timeout in Settings."

    /// Nil while no restart is under way, so the chip shows Symphony's state. `window` names the runs.
    public init?(machine: RestartMachine, window: ReposWindow) {
        let update = machine.purpose.isUpdate
        let pending = update ? "Update pending" : "Restart pending"
        switch machine.phase {
        case .idle:
            return nil
        case .checkingConfig, .pausing, .waitingForRuns(running: nil):
            title = pending
        case let .waitingForRuns(running: count?):
            title = "\(pending): waiting on \(count) \(count == 1 ? "run" : "runs")"
        case .stopping, .starting, .waitingForAnswer, .resuming:
            title = update ? "Updating Symphony…" : "Restarting Symphony…"
        }
        line = machine.menuLine
        runs = window.repos.flatMap { repo -> [String] in
            guard case let .status(_, _, agents, _) = repo.live else { return [] }
            return agents.map { "\(repo.key): \($0.title)" }
        }
        showsCancel = machine.canCancel
        showsRestartNow = machine.canCancel
        restartNowEnabled = machine.offersRestartNow
        restartNowTitle = update ? Self.updateNowTitle : Self.restartNowTitle
        cancelTitle = update ? UpdateMenu.cancelUpdateTitle : StatusMenu.cancelRestartTitle
    }
}
