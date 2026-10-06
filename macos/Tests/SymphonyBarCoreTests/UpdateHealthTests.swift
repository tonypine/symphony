import XCTest
@testable import SymphonyBarCore

final class UpdateHealthTests: XCTestCase {
    private typealias Health = UpdateHealthCheck

    private let updated = Date(timeIntervalSince1970: 1_790_000_000)
    private let log = "~/Library/Logs/Symphony/symphony.log"
    private let answered = StatusPoll.state(StateSnapshot())

    private func at(_ seconds: TimeInterval) -> Date {
        updated.addingTimeInterval(seconds)
    }

    private static func release(build: Int) -> Release {
        Release(
            version: "0.0.1.\(build)",
            build: build,
            notes: "",
            pageURL: URL(string: "https://github.com/tonypine/symphony/releases/tag/v0.0.1.\(build)")!,
            changes: nil
        )
    }

    /// A check on v0.0.1.43 whose config check passed and whose Symphony started at `startedAt` seconds.
    private func started(at startedAt: TimeInterval = 5) -> Health {
        var health = Health()
        XCTAssertEqual(health.begin(version: "0.0.1.43", startsSymphony: true, now: updated), [.checkConfig])
        XCTAssertEqual(health.handle(.configChecked(.passed), now: at(2)), [.start])
        XCTAssertEqual(health.handle(.started, now: at(startedAt)), [])
        XCTAssertEqual(health.phase, .waitingForAnswer)
        return health
    }

    /// A check whose Symphony answered at 30 seconds.
    private func watching() -> Health {
        var health = started()
        XCTAssertEqual(health.handle(.polled(answered), now: at(30)), [.healthy])
        XCTAssertEqual(health.phase, .watching)
        return health
    }

    // MARK: Health check

    func testFailingConfigCheckRollsBack() {
        var health = Health()
        XCTAssertEqual(health.begin(version: "0.0.1.43", startsSymphony: true, now: updated), [.checkConfig])
        XCTAssertTrue(health.isChecking)
        XCTAssertEqual(health.menuLine, "Checking v0.0.1.43: running symphony check…")

        let message = "Config error: workspaces.repo does not exist: /Users/me/missing"
        XCTAssertEqual(health.handle(.configChecked(.failed(message)), now: at(3)), [.rollBack(.configCheck(message))])
        XCTAssertEqual(health.phase, .failed(.configCheck(message)))
        XCTAssertFalse(health.isActive)
        XCTAssertNil(health.menuLine)
    }

    func testOnlyTheConfigCheckRunsWhenSymphonyDoesNotStart() {
        var health = Health()
        _ = health.begin(version: "0.0.1.43", startsSymphony: false, now: updated)

        XCTAssertEqual(health.handle(.configChecked(.passed), now: at(3)), [.healthy])
        XCTAssertEqual(health.phase, .passed)
        XCTAssertFalse(health.isActive)
        XCTAssertEqual(health.handle(.exited(requested: false), now: at(60)), [], "no restart once the check passed")
    }

    func testHealthyUpdateAnswersAndOutlastsTheWindow() {
        var health = started()
        XCTAssertEqual(health.menuLine, "Checking v0.0.1.43: waiting for Symphony to answer…")
        XCTAssertEqual(health.handle(.polled(.unreachable), now: at(60)), [])
        XCTAssertEqual(health.handle(.polled(answered), now: at(70)), [.healthy], "healthy once Symphony answers")
        XCTAssertEqual(health.phase, .watching)
        XCTAssertFalse(health.isChecking, "automatic updates may go ahead once Symphony answers")
        XCTAssertTrue(health.isActive)
        XCTAssertNil(health.menuLine)

        XCTAssertEqual(health.handle(.polled(answered), now: at(Health.crashWindow - 1)), [])
        XCTAssertEqual(health.phase, .watching)
        XCTAssertEqual(health.handle(.polled(answered), now: at(Health.crashWindow)), [])
        XCTAssertEqual(health.phase, .passed)
    }

    func testNoAnswerWithin120SecondsOfStartingRollsBack() {
        XCTAssertEqual(Health.answerTimeout, 120)
        var health = started(at: 5)

        XCTAssertEqual(health.handle(.polled(.unreachable), now: at(124)), [])
        XCTAssertEqual(health.handle(.polled(.failed("HTTP 500")), now: at(125)), [.rollBack(.noAnswer)])
        XCTAssertEqual(health.phase, .failed(.noAnswer))
    }

    func testThreeUnexpectedExitsWithinTenMinutesRollBack() {
        var health = watching()

        // Each of the first two exits starts Symphony again, which must answer again.
        XCTAssertEqual(health.handle(.exited(requested: false), now: at(60)), [.start])
        XCTAssertEqual(health.phase, .starting)
        XCTAssertTrue(health.isChecking)
        XCTAssertEqual(health.handle(.started, now: at(65)), [])
        // An exit before answering counts too.
        XCTAssertEqual(health.handle(.exited(requested: false), now: at(120)), [.start])
        XCTAssertEqual(health.handle(.started, now: at(125)), [])
        XCTAssertEqual(health.unexpectedExits, 2)

        XCTAssertEqual(health.handle(.exited(requested: false), now: at(Health.crashWindow - 1)), [.rollBack(.crashLoop)])
        XCTAssertEqual(health.unexpectedExits, 3)
        XCTAssertEqual(health.phase, .failed(.crashLoop))
    }

    func testARestartAfterAnExitHasItsOwnAnswerDeadline() {
        var health = watching()
        XCTAssertEqual(health.handle(.exited(requested: false), now: at(300)), [.start])
        XCTAssertEqual(health.handle(.started, now: at(310)), [])

        XCTAssertEqual(health.handle(.polled(.unreachable), now: at(429)), [])
        XCTAssertEqual(health.handle(.polled(.unreachable), now: at(430)), [.rollBack(.noAnswer)])
    }

    func testAnUnexpectedExitAfterTheWindowIsLeftAlone() {
        var health = watching()
        XCTAssertEqual(health.handle(.exited(requested: false), now: at(60)), [.start])
        XCTAssertEqual(health.handle(.started, now: at(65)), [])
        XCTAssertEqual(health.handle(.polled(answered), now: at(70)), [], "the update is reported healthy only once")

        XCTAssertEqual(health.handle(.exited(requested: false), now: at(Health.crashWindow)), [])
        XCTAssertEqual(health.phase, .passed)
        XCTAssertEqual(health.unexpectedExits, 1)
    }

    func testAStopYouMakeIsNotCounted() {
        var health = watching()
        XCTAssertEqual(health.handle(.exited(requested: true), now: at(60)), [])
        XCTAssertEqual(health.phase, .watching)
        XCTAssertEqual(health.unexpectedExits, 0)

        // Stopped before it answered: nothing is left to wait for.
        var stopped = started()
        XCTAssertEqual(stopped.handle(.exited(requested: true), now: at(10)), [.healthy])
        XCTAssertEqual(stopped.phase, .watching)
        XCTAssertEqual(stopped.handle(.polled(.unreachable), now: at(200)), [])
    }

    func testASymphonyTheAppDidNotStartIsNotWaitedFor() {
        var health = Health()
        _ = health.begin(version: "0.0.1.43", startsSymphony: true, now: updated)
        XCTAssertEqual(health.handle(.configChecked(.passed), now: at(2)), [.start])

        XCTAssertEqual(health.handle(.notStarted, now: at(5)), [.healthy])
        XCTAssertEqual(health.phase, .watching)
        XCTAssertEqual(health.handle(.polled(.unreachable), now: at(300)), [])
    }

    func testEventsOutsideTheirStepChangeNothing() {
        var health = Health()
        XCTAssertEqual(health.handle(.exited(requested: false), now: at(1)), [], "no check, no restart")
        XCTAssertEqual(health.phase, .idle)
        XCTAssertFalse(health.isActive)

        _ = health.begin(version: "0.0.1.43", startsSymphony: true, now: updated)
        XCTAssertEqual(health.begin(version: "0.0.1.44", startsSymphony: true, now: at(1)), [])
        XCTAssertEqual(health.handle(.polled(.unreachable), now: at(500)), [], "the answer deadline starts with Symphony")
        XCTAssertEqual(health.handle(.started, now: at(2)), [])
        XCTAssertEqual(health.phase, .checkingConfig)
        XCTAssertEqual(health.version, "0.0.1.43")
    }

    func testFailureReasonsNameTheCheckAndTheLog() {
        XCTAssertEqual(
            UpdateHealthFailure.configCheck("Config error: workspaces.repo does not exist").reason(logPath: log),
            "symphony check failed: Config error: workspaces.repo does not exist"
        )
        XCTAssertEqual(
            UpdateHealthFailure.noAnswer.reason(logPath: log),
            "Symphony didn't answer within 120 seconds of starting; see \(log)"
        )
        XCTAssertEqual(
            UpdateHealthFailure.crashLoop.reason(logPath: log),
            "Symphony stopped unexpectedly 3 times within 10 minutes; see \(log)"
        )
    }

    // MARK: Rollback record and relaunch

    private let record = RollbackRecord(
        build: 43,
        version: "0.0.1.43",
        reason: "symphony check failed: Config error: workspaces.repo does not exist",
        startSymphony: true,
        resumeDispatch: true
    )

    func testRollbackRecordIsReadOnceByTheRestoredApp() {
        let defaults = MemoryKeyValueStore()
        RollbackStore(defaults: defaults).save(record)

        let restored = RollbackStore(defaults: defaults)
        XCTAssertEqual(restored.take(), record)
        XCTAssertNil(defaults.values[RollbackStore.key])
        XCTAssertNil(restored.take())
    }

    func testRollbackRecordKeepsTheFailedReleasesNotes() {
        let defaults = MemoryKeyValueStore()
        var withNotes = record
        withNotes.details = ReleaseDetails(Self.release(build: 43))
        withNotes.details.notes = "12 changes since v0.0.1.42:\n- Fix"
        withNotes.details.changes = 12
        RollbackStore(defaults: defaults).save(withNotes)

        let restored = RollbackStore(defaults: defaults).take()
        XCTAssertEqual(restored, withNotes)
        XCTAssertEqual(
            restored?.details.release(version: "0.0.1.43", build: 43)?.notes,
            "12 changes since v0.0.1.42:\n- Fix"
        )
    }

    func testUnreadableRollbackRecordIsDropped() {
        let defaults = MemoryKeyValueStore()
        defaults.values[RollbackStore.key] = ["build": "43"]

        XCTAssertNil(RollbackStore(defaults: defaults).take())
        XCTAssertNil(defaults.values[RollbackStore.key])

        let store = RollbackStore(defaults: defaults)
        store.save(record)
        store.clear()
        XCTAssertNil(store.take())
    }

    func testRelaunchDecision() {
        let pending = PendingUpdate(fromBuild: 42, toBuild: 43, version: "0.0.1.43", startSymphony: true, resumeDispatch: true)

        XCTAssertEqual(UpdateRelaunch(pending: nil, rollback: nil, runningBuild: 43), .none)
        XCTAssertEqual(UpdateRelaunch(pending: pending, rollback: nil, runningBuild: 43), .checkHealth(pending))
        XCTAssertEqual(UpdateRelaunch(pending: pending, rollback: nil, runningBuild: 42), .notReplaced(pending))
        XCTAssertEqual(UpdateRelaunch(pending: nil, rollback: record, runningBuild: 42), .rolledBack(record))
        XCTAssertEqual(UpdateRelaunch(pending: nil, rollback: record, runningBuild: 43), .rollbackFailed(record))

        // A version from before automatic rollback was put back and never read the record, then updated again.
        let newer = PendingUpdate(fromBuild: 42, toBuild: 44, version: "0.0.1.44", startSymphony: true, resumeDispatch: true)
        XCTAssertEqual(
            UpdateRelaunch(pending: newer, rollback: record, runningBuild: 44),
            .checkHealth(newer),
            "a stale rollback record doesn't stop the next update's health check"
        )
        XCTAssertEqual(UpdateRelaunch(pending: newer, rollback: record, runningBuild: 42), .notReplaced(newer))
    }

    func testStaleRollbackRecordDoesNotSkipTheHealthCheckOfTheSameBuild() {
        // A version from before automatic rollback was put back, never read the record or the pin, and installed the
        // rolled-back build again: toBuild <= record.build, and nothing pins it any more. The decision reads no pin.
        let retry = PendingUpdate(fromBuild: 42, toBuild: 43, version: "0.0.1.43", startSymphony: true, resumeDispatch: false)
        XCTAssertEqual(
            UpdateRelaunch(pending: retry, rollback: record, runningBuild: 43),
            .checkHealth(retry),
            "a stale rollback record doesn't stop the health check of the build it names"
        )
        XCTAssertEqual(UpdateRelaunch(pending: retry, rollback: record, runningBuild: 42), .notReplaced(retry))

        let older = PendingUpdate(fromBuild: 41, toBuild: 42, version: "0.0.1.42", startSymphony: false, resumeDispatch: false)
        XCTAssertEqual(UpdateRelaunch(pending: older, rollback: record, runningBuild: 42), .checkHealth(older))

        // Installed by hand over it, without an update: a newer build than the record runs.
        XCTAssertEqual(UpdateRelaunch(pending: nil, rollback: record, runningBuild: 44), .none)
    }

    // MARK: Pin and Retry

    func testTheRolledBackBuildIsPinnedAndOffersRetry() {
        let skips = SkippedReleaseStore(defaults: MemoryKeyValueStore())
        let bad = Self.release(build: 43)
        skips.record(SkippedRelease(bad, reason: .rolledBack))

        let offer = UpdateOffer(bad, skips: skips)
        XCTAssertEqual(offer, .skipped(bad, .rolledBack))
        XCTAssertEqual(offer.installTitle, "Retry v0.0.1.43")
        XCTAssertFalse(offer.offersSkip)
        XCTAssertEqual(offer.title(current: AppBuild(build: 42, isDevelopment: false)), "Update rolled back: v0.0.1.43")

        XCTAssertEqual(UpdateOffer.available(bad).installTitle, "Update to v0.0.1.43")
        XCTAssertEqual(UpdateOffer.skipped(bad, .skipped).installTitle, "Update to v0.0.1.43")

        // Retry and Update to vX clear the pin once confirmed.
        skips.clear(build: 43)
        XCTAssertEqual(UpdateOffer(bad, skips: skips), .available(bad))
    }

    func testAutoUpdateSkipsThePinnedBuildButInstallsANewerOne() {
        let skips = SkippedReleaseStore(defaults: MemoryKeyValueStore())
        skips.record(SkippedRelease(Self.release(build: 43), reason: .rolledBack))
        func context(_ release: Release) -> AutoUpdater.Context {
            AutoUpdater.Context(
                mode: .whenIdle,
                time: .defaultUpdateTime,
                offer: UpdateOffer(release, skips: skips),
                blocker: nil,
                activity: .notRunning,
                runsTimeout: 0
            )
        }
        var updater = AutoUpdater()

        XCTAssertNil(updater.checked(.available(Self.release(build: 43)), context(Self.release(build: 43))))
        let newer = Self.release(build: 44)
        XCTAssertEqual(updater.checked(.available(newer), context(newer)), .install(newer, runsTimeout: 0))
    }

    func testMenuLinesSayWhyAndHowToRollBackByHand() {
        XCTAssertEqual(
            UpdateMenu.rolledBackLine(record),
            "v0.0.1.43 was rolled back: symphony check failed: Config error: workspaces.repo does not exist"
        )
        let reason = "Symphony stopped unexpectedly 3 times within 10 minutes; see \(log)"
        XCTAssertEqual(
            UpdateMenu.rollbackFailedLine(version: "0.0.1.43", reason: reason, problem: .noPreviousApp),
            "v0.0.1.43 failed its check (\(reason)) and couldn't be rolled back: there is no Symphony (previous).app. "
                + "To go back, quit Symphony and reinstall the previous release with the install script "
                + "(SYMPHONY_RELEASE_TAG)."
        )
        let byHand = "To roll back by hand, quit Symphony, rename Symphony.app to Symphony (rolled back).app and "
            + "Symphony (previous).app to Symphony.app, then open it."
        XCTAssertEqual(
            UpdateMenu.rollbackFailedLine(
                version: "0.0.1.43",
                reason: reason,
                problem: .swapFailed(logPath: "~/Library/Caches/com.tonypine.symphony.bar/rollback-helper.log")
            ),
            "v0.0.1.43 failed its check (\(reason)) and couldn't be rolled back: the apps couldn't be swapped; see "
                + "~/Library/Caches/com.tonypine.symphony.bar/rollback-helper.log. \(byHand)"
        )
        XCTAssertEqual(
            UpdateMenu.rollbackFailedLine(version: "0.0.1.43", reason: reason, problem: .helper("permission denied")),
            "v0.0.1.43 failed its check (\(reason)) and couldn't be rolled back: permission denied. \(byHand)"
        )
    }
}
