import Foundation

/// Automatically when released, from a verified download to the swap (TP-1590), kept free of AppKit so it can be unit
/// tested. The app doesn't pause dispatch to wait behind agent runs: it tells Symphony the update is ready, and
/// Symphony keeps dispatching until the first moment no agent run is active, when it pauses on the update's `build`
/// reason itself. The app swaps once a poll shows that pause, so dispatch is held only for the restart.
///
/// While the update waits, a newer release that is downloaded and verified replaces it and is armed in its place, so
/// the app restarts once, onto the newest build. Only a verified release is ever armed: one still downloading never
/// holds up a swap whose moment has come.
public struct UpdateArming: Equatable {
    /// Symphony refused this many arms in a row (a Symphony older than the app): the update drains as before.
    public static let armAttempts = 3

    public enum Effect: Equatable {
        /// Tell Symphony the update to `version` is ready (`ControlAction.updateReady`).
        case arm(version: String)
        /// Symphony paused for the update, or doesn't run: drain behind its pause and swap to `update`.
        case swap(PreparedUpdate)
        /// Symphony can't take an update ready: pause and drain as Update to vX does, then swap to `update`.
        case drain(PreparedUpdate)
        /// Call the update off on Symphony's side (`ControlAction.resumeUpdate`).
        case disarm(version: String)
    }

    /// The newest verified release, which the swap installs; nil when none waits.
    public private(set) var target: PreparedUpdate?
    /// True from the swap's start until its drain ends.
    public private(set) var swapping = false
    /// The version of the arm in flight, so a poll doesn't send it again before Symphony answers.
    private var arming: String?
    private var refusals = 0

    public init() {}

    /// The version that waits for its moment while dispatch goes on; nil while none does, or once the swap started.
    public var waitingVersion: String? { swapping ? nil : target?.release.version }

    /// The build the update waits with, so only a newer one is downloaded meanwhile.
    public var build: Int? { target?.release.build }

    /// A release was downloaded and verified. A newer one than the update waiting replaces it; an older one, or one
    /// verified once the swap started, changes nothing.
    public mutating func verified(_ update: PreparedUpdate) -> [Effect] {
        guard !swapping else { return [] }
        if let target, update.release.build <= target.release.build { return [] }
        target = update
        refusals = 0
        arming = update.release.version
        return [.arm(version: update.release.version)]
    }

    /// Symphony answered the arm of `version`. After `armAttempts` refusals in a row the update drains as before.
    public mutating func armed(_ version: String, result: ControlResult) -> [Effect] {
        guard let target, !swapping, target.release.version == version else { return [] }
        arming = nil
        guard case .failed = result else {
            refusals = 0
            return []
        }
        refusals += 1
        guard refusals >= Self.armAttempts else { return [] }
        swapping = true
        return [.drain(target)]
    }

    /// Each status poll. `window` is the update Symphony has ready, `pauseVersion` the version its pause's update
    /// reason waits on, and `activity` what Symphony is doing, without the download of a newer release counting as
    /// busy. A Symphony that forgot the update (it restarted) is armed again.
    public mutating func polled(window: StateSnapshot.UpdateWindow?, pauseVersion: String?, activity: SymphonyActivity) -> [Effect] {
        guard let target, !swapping else { return [] }
        let version = target.release.version
        switch activity {
        case .busy:
            return []
        case .notRunning:
            swapping = true
            return [.swap(target)]
        case .running:
            if pauseVersion == version {
                swapping = true
                return [.swap(target)]
            }
            guard window?.version != version, arming == nil else { return [] }
            arming = version
            return [.arm(version: version)]
        }
    }

    /// The swap's drain ended. `waitsAgain` when Symphony lifted its hold (it reached its limit with runs still
    /// active): the update waits for its next moment. Otherwise Symphony stopped and the handover follows, or the swap
    /// failed or was called off, and nothing waits any more.
    public mutating func drainEnded(waitsAgain: Bool) {
        guard swapping else { return }
        swapping = false
        arming = nil
        if !waitsAgain { self = UpdateArming() }
    }

    /// Cancel Update while the update waits: it is called off on Symphony's side. During the swap the drain's own
    /// Cancel lifts Symphony's pause, so nothing more is sent.
    public mutating func cancel() -> [Effect] {
        guard let target else { return [] }
        let swapping = swapping
        self = UpdateArming()
        return swapping ? [] : [.disarm(version: target.release.version)]
    }
}
