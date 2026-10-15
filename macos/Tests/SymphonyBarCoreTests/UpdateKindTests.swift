import XCTest
@testable import SymphonyBarCore

final class UpdateKindTests: XCTestCase {
    private let release = Release(
        version: "0.0.1.42",
        build: 42,
        notes: "12 changes since v0.0.1.41:",
        pageURL: URL(string: "https://github.com/tonypine/symphony/releases/tag/v0.0.1.42")!,
        changes: 12
    )

    // MARK: Kind

    func testOnReleaseDrainsAsUpdateToVXWithoutAsking() {
        XCTAssertEqual(UpdateKind.onRelease.drainPurpose, .update, "waits without giving up, offers Update Now Anyway")
        XCTAssertEqual(UpdateKind.onRelease.runsTimeout(restartTimeout: 1800), 1800)
        XCTAssertTrue(UpdateKind.onRelease.isAutomatic)
        XCTAssertTrue(UpdateKind.onRelease.announcesStart)
    }

    func testTheOtherKindsKeepTheirDrains() {
        XCTAssertEqual(UpdateKind.manual.drainPurpose, .update)
        XCTAssertEqual(UpdateKind.manual.runsTimeout(restartTimeout: 1800), 1800)
        XCTAssertFalse(UpdateKind.manual.isAutomatic)
        XCTAssertEqual(UpdateKind.automatic(runsTimeout: 0).drainPurpose, .automaticUpdate)
        XCTAssertEqual(UpdateKind.automatic(runsTimeout: 600).runsTimeout(restartTimeout: 1800), 600)
        XCTAssertTrue(UpdateKind.automatic(runsTimeout: 0).isAutomatic)
        for kind in [UpdateKind.manual, .automatic(runsTimeout: 0)] {
            XCTAssertFalse(kind.announcesStart, "\(kind)")
        }
    }

    func testAnOnReleaseUpdateIsRecordedAsAutomatic() {
        let pending = UpdateKind.onRelease.pendingUpdate(release, fromBuild: 41, startSymphony: true, resumeDispatch: true)

        XCTAssertEqual(
            pending,
            PendingUpdate(
                fromBuild: 41,
                toBuild: 42,
                version: "0.0.1.42",
                startSymphony: true,
                resumeDispatch: true,
                details: ReleaseDetails(release),
                automatic: true
            )
        )
        // So the relaunched app posts "Symphony updated to vX" once it is healthy (S4a).
        XCTAssertEqual(
            UpdateNotice.updated(LastUpdate(pending, installedAt: Date())).title,
            "Symphony updated to v0.0.1.42"
        )
    }

    func testOnlyUpdateToVXIsRecordedAsManual() {
        let manual = UpdateKind.manual.pendingUpdate(release, fromBuild: 41, startSymphony: false, resumeDispatch: false)
        let idle = UpdateKind.automatic(runsTimeout: 0).pendingUpdate(release, fromBuild: 41, startSymphony: false, resumeDispatch: false)

        XCTAssertFalse(manual.automatic)
        XCTAssertTrue(idle.automatic)
    }

    func testAFailureBeforeTheSwapTriesAgainAtTheNextCheckWhenReleased() {
        XCTAssertEqual(
            UpdateKind.onRelease.failureLine("the checksum doesn't match"),
            "Symphony wasn't updated: the checksum doesn't match. Trying again at the next check."
        )
        XCTAssertEqual(
            UpdateKind.onRelease.failureLine("The operation couldn’t be completed."),
            "Symphony wasn't updated: The operation couldn’t be completed. Trying again at the next check."
        )
        XCTAssertEqual(UpdateKind.manual.failureLine("the checksum doesn't match"), "Symphony wasn't updated: the checksum doesn't match")
        XCTAssertEqual(
            UpdateKind.automatic(runsTimeout: 0).failureLine("the checksum doesn't match"),
            "Symphony wasn't updated: the checksum doesn't match"
        )
    }

    // MARK: Cancel Update

    /// The drain of an update of `kind`, waiting for one agent run; `stopping` takes it on to the swap.
    private func drain(_ kind: UpdateKind, stopping: Bool = false) -> RestartMachine {
        var machine = RestartMachine()
        let began = Date(timeIntervalSince1970: 1_000_000)
        _ = machine.begin(
            alreadyPaused: false,
            purpose: kind.drainPurpose,
            runsTimeout: kind.runsTimeout(restartTimeout: 1800),
            logPath: "log",
            alerts: !kind.isAutomatic,
            now: began
        )
        _ = machine.handle(.configChecked(.passed), now: began)
        _ = machine.handle(.controlFinished(.pause, .done), now: began)
        let running = stopping ? 0 : 1
        _ = machine.handle(.polled(.state(StateSnapshot(running: running, pause: .init(reason: ControlAction.pauseReason)))), now: began)
        return machine
    }

    func testCancelUpdateOnAnOnReleaseUpdateHoldsItsRelease() {
        let waiting = UpdateCancel(downloading: false, drain: drain(.onRelease), kind: .onRelease, release: release)
        XCTAssertEqual(waiting?.step, .drain)
        XCTAssertEqual(waiting?.hold, release)

        let downloading = UpdateCancel(downloading: true, drain: RestartMachine(), kind: .onRelease, release: release)
        XCTAssertEqual(downloading?.step, .download)
        XCTAssertEqual(downloading?.hold, release)
    }

    func testCancelUpdateHoldsNothingForTheOtherKinds() {
        for kind in [UpdateKind.manual, .automatic(runsTimeout: 1800)] {
            let cancel = UpdateCancel(downloading: false, drain: drain(kind), kind: kind, release: release)
            XCTAssertEqual(cancel?.step, .drain, "\(kind)")
            XCTAssertNil(cancel?.hold, "\(kind)")
        }
    }

    func testCancelUpdateDoesNothingOnceTheUpdateReachedTheSwapOrEnded() {
        let stopping = drain(.onRelease, stopping: true)
        XCTAssertEqual(stopping.phase, .stopping)
        XCTAssertNil(UpdateCancel(downloading: false, drain: stopping, kind: .onRelease, release: release), "the swap")
        XCTAssertNil(UpdateCancel(downloading: false, drain: RestartMachine(), kind: .onRelease, release: release), "ended")

        var restart = RestartMachine()
        _ = restart.begin(alreadyPaused: true, runsTimeout: 1800, logPath: "log")
        _ = restart.handle(.configChecked(.passed))
        XCTAssertTrue(restart.canCancel)
        XCTAssertNil(
            UpdateCancel(downloading: false, drain: restart, kind: .onRelease, release: release),
            "a restart is Cancel Restart's"
        )
    }

    func testTheHoldFromCancelUpdateKeepsTheReleaseFromInstallingAgain() {
        var updater = AutoUpdater()
        let context = AutoUpdater.Context(
            mode: .onRelease,
            time: .defaultUpdateTime,
            offer: .available(release),
            blocker: nil,
            activity: .running(activeRuns: 1),
            runsTimeout: 1800
        )
        XCTAssertEqual(updater.checked(.available(release), context), .install(release, kind: .onRelease))

        let cancel = UpdateCancel(downloading: false, drain: drain(.onRelease), kind: .onRelease, release: release)
        cancel?.hold.map { updater.hold($0) }

        XCTAssertNil(updater.checked(.available(release), context))
    }

    // MARK: Menu (S2b–S2f)

    func testMenuLines() {
        XCTAssertEqual(UpdateMenu.preparingLine(release), "Updating: downloading and verifying v0.0.1.42…")
        XCTAssertEqual(UpdateMenu.cancelUpdateTitle, "Cancel Update")
        XCTAssertEqual(UpdateMenu.updateNowTitle, "Update Now Anyway")
        XCTAssertEqual(
            UpdateMenu.waitingLine(version: "0.0.1.42", activeRuns: 1, minutes: nil),
            "Updating to v0.0.1.42: waiting for 1 agent run…"
        )
        XCTAssertEqual(
            UpdateMenu.waitingLine(version: "0.0.1.42", activeRuns: 3, minutes: 42),
            "Updating to v0.0.1.42: waiting for 3 agent runs… (42 min)"
        )
        XCTAssertEqual(
            UpdateMenu.cancelledLine,
            "You cancelled this update. It waits for you; a newer release installs by itself."
        )
        XCTAssertEqual(UpdateOffer.available(release).installTitle, "Update to v0.0.1.42")
        XCTAssertTrue(UpdateOffer.available(release).offersSkip, "Skip This Version shows for a held release")
    }

    // MARK: Start notification (S4c)

    func testStartNotificationWording() {
        let one = UpdateNotice.updateStarted(version: "0.0.1.42", activeRuns: 1)
        XCTAssertEqual(one.title, "Updating Symphony to v0.0.1.42")
        XCTAssertEqual(one.body, "Dispatch is paused until 1 agent run finishes. Symphony then updates and resumes dispatch.")
        XCTAssertEqual(
            one.messageWithCancelUpdate,
            "Dispatch is paused until 1 agent run finishes. Symphony then updates and resumes dispatch. · Cancel Update"
        )
        XCTAssertEqual(
            UpdateNotice.updateStarted(version: "0.0.1.42", activeRuns: 3).body,
            "Dispatch is paused until 3 agent runs finish. Symphony then updates and resumes dispatch."
        )
        XCTAssertEqual(
            UpdateNotice.updateStarted(version: "0.0.1.42", activeRuns: 0).body,
            "Symphony is updating and resumes dispatch when it is done."
        )
        XCTAssertEqual(UpdateNotice.cancelUpdateTitle, "Cancel Update")
    }

    func testStartNotificationIsDueOnceWhenTheDrainKnowsItsRuns() {
        var notifier = UpdateStartNotifier()
        notifier.began(release, kind: .onRelease)

        XCTAssertNil(notifier.drained(.checkingConfig))
        XCTAssertNil(notifier.drained(.pausing))
        XCTAssertNil(notifier.drained(.waitingForRuns(running: nil)))
        XCTAssertEqual(notifier.drained(.waitingForRuns(running: 1)), .post(.updateStarted(version: "0.0.1.42", activeRuns: 1)))
        XCTAssertTrue(notifier.isPosted)
        XCTAssertNil(notifier.drained(.waitingForRuns(running: 2)), "once per update")
        XCTAssertNil(notifier.drained(.stopping))
    }

    func testStartNotificationWithNoActiveRun() {
        var notifier = UpdateStartNotifier()
        notifier.began(release, kind: .onRelease)
        XCTAssertNil(notifier.drained(.waitingForRuns(running: nil)))

        XCTAssertEqual(notifier.drained(.stopping), .post(.updateStarted(version: "0.0.1.42", activeRuns: 0)))
    }

    func testTheOtherModesPostNoStartNotification() {
        for kind in [UpdateKind.manual, .automatic(runsTimeout: 0), .automatic(runsTimeout: 1800)] {
            var notifier = UpdateStartNotifier()
            notifier.began(release, kind: kind)

            XCTAssertNil(notifier.drained(.waitingForRuns(running: 1)), "\(kind)")
            XCTAssertNil(notifier.drained(.stopping), "\(kind)")
            XCTAssertNil(notifier.ended(), "\(kind)")
        }
    }

    func testStartNotificationIsWithdrawnWhenTheUpdateEnds() {
        var notifier = UpdateStartNotifier()
        notifier.began(release, kind: .onRelease)
        _ = notifier.drained(.waitingForRuns(running: 1))

        XCTAssertEqual(notifier.ended(), .withdraw, "ended, failed or cancelled")
        XCTAssertFalse(notifier.isPosted)
        XCTAssertNil(notifier.ended(), "withdrawn once")
    }

    func testAnUpdateThatEndsBeforeItsNoticeWithdrawsNothingAndPostsNothingLater() {
        var notifier = UpdateStartNotifier()
        notifier.began(release, kind: .onRelease)

        XCTAssertNil(notifier.ended(), "a download that failed or was cancelled")
        XCTAssertNil(notifier.drained(.waitingForRuns(running: 1)), "a later restart's drain posts nothing")
    }

    func testANewUpdateIsDueAgain() {
        var notifier = UpdateStartNotifier()
        notifier.began(release, kind: .onRelease)
        _ = notifier.drained(.waitingForRuns(running: 1))
        _ = notifier.ended()

        notifier.began(release, kind: .onRelease)

        XCTAssertEqual(notifier.drained(.waitingForRuns(running: 2)), .post(.updateStarted(version: "0.0.1.42", activeRuns: 2)))
        XCTAssertEqual(UpdateStartNotifier.requestIdentifier, "symphony.update.started")
    }

    // MARK: The window during an update (S3a, S3b)

    func testTheWindowSeesTheUpdateFromItsDownloadToTheSwap() {
        let downloading = UpdateHold(release: release, downloading: true, drain: RestartMachine())
        XCTAssertEqual(downloading, UpdateHold(version: "0.0.1.42", step: .preparing))
        XCTAssertEqual(downloading?.title, "Updating to v0.0.1.42")
        XCTAssertEqual(downloading?.canCancel, false)
        XCTAssertNil(downloading?.waitingLine)

        var machine = RestartMachine()
        _ = machine.begin(alreadyPaused: false, purpose: .update, updatingTo: release.version, runsTimeout: 1800, logPath: "log")
        XCTAssertEqual(UpdateHold(release: release, downloading: false, drain: machine)?.step, .preparing, "checking symphony.yml")
        _ = machine.handle(.configChecked(.passed))
        XCTAssertEqual(UpdateHold(release: release, downloading: false, drain: machine)?.step, .preparing, "pausing")

        let waiting = UpdateHold(release: release, downloading: false, drain: drain(.onRelease))
        XCTAssertEqual(waiting, UpdateHold(version: "0.0.1.42", step: .waiting(runs: 1)))
        XCTAssertEqual(waiting?.canCancel, true)
        XCTAssertEqual(waiting?.waitingLine, "Waiting for 1 agent run")

        let stopping = UpdateHold(release: release, downloading: false, drain: drain(.onRelease, stopping: true))
        XCTAssertEqual(stopping?.step, .stopping)
        XCTAssertEqual(stopping?.canCancel, false)
        XCTAssertNil(stopping?.waitingLine)
    }

    func testTheUpdateOffersUpdateNowAnywayOnceTheRunsOutlastTheTimeout() {
        var machine = drain(.manual)
        let later = Date(timeIntervalSince1970: 1_000_000 + 1800)
        _ = machine.handle(.polled(.state(StateSnapshot(running: 2, pause: .init(reason: "updating to v0.0.1.42")))), now: later)

        let hold = UpdateHold(release: release, downloading: false, drain: machine)
        XCTAssertEqual(hold, UpdateHold(version: "0.0.1.42", step: .waiting(runs: 2), offersUpdateNow: true))
        XCTAssertEqual(hold?.waitingLine, "Waiting for 2 agent runs")
        XCTAssertEqual(UpdateHold(version: "1", step: .waiting(runs: nil)).waitingLine, "Waiting for dispatch to pause")
    }

    func testNoUpdateHoldsDispatchWithoutOneUnderWay() {
        XCTAssertNil(UpdateHold(release: nil, downloading: false, drain: drain(.manual)), "no release")
        XCTAssertNil(UpdateHold(release: release, downloading: false, drain: RestartMachine()), "the drain ended")

        var restart = RestartMachine()
        _ = restart.begin(alreadyPaused: true, runsTimeout: 1800, logPath: "log")
        XCTAssertNil(UpdateHold(release: release, downloading: false, drain: restart), "a restart")

        var cancelled = drain(.onRelease)
        XCTAssertEqual(cancelled.handle(.cancel), [.send(.resume)])
        XCTAssertNil(UpdateHold(release: release, downloading: false, drain: cancelled), "Cancel Update resumes dispatch")
    }

    func testTheUpdatesPauseReasonNamesItsVersion() {
        XCTAssertEqual(ControlAction.updatePauseReason(version: "0.0.1.42"), "updating to v0.0.1.42")
        XCTAssertEqual(ControlAction.updateVersion(pauseReason: " updating to v0.0.1.42 "), "0.0.1.42")
        XCTAssertNil(ControlAction.updateVersion(pauseReason: "updating to v"))
        XCTAssertNil(ControlAction.updateVersion(pauseReason: ControlAction.pauseReason))
        XCTAssertNil(ControlAction.updateVersion(pauseReason: nil))
    }
}
