import XCTest
@testable import SymphonyBarCore

final class UpdateOutcomeTests: XCTestCase {
    private let installedAt = Date(timeIntervalSince1970: 1_790_000_000)
    private let pageURL = URL(string: "https://github.com/tonypine/symphony/releases/tag/v0.0.1.43")!
    private let notes = "12 changes since v0.0.1.42:\n\n- feat: something (abc1234)"

    private func details(changes: Int? = 12) -> ReleaseDetails {
        ReleaseDetails(notes: notes, pageURL: pageURL, changes: changes)
    }

    private func update(changes: Int? = 12) -> LastUpdate {
        LastUpdate(version: "0.0.1.43", build: 43, details: details(changes: changes), installedAt: installedAt)
    }

    private func rollback(details: ReleaseDetails = ReleaseDetails()) -> RollbackRecord {
        RollbackRecord(
            build: 43,
            version: "0.0.1.43",
            reason: "symphony check failed: Config error: workspaces.repo does not exist",
            startSymphony: true,
            resumeDispatch: false,
            details: details
        )
    }

    // MARK: Last update

    func testTheHealthyUpdateIsRecordedFromThePendingUpdate() {
        let pending = PendingUpdate(
            fromBuild: 42,
            toBuild: 43,
            version: "0.0.1.43",
            startSymphony: true,
            resumeDispatch: false,
            details: details(),
            automatic: true
        )
        XCTAssertEqual(LastUpdate(pending, installedAt: installedAt), update())
    }

    func testTheLineShowsForSevenDaysOnTheUpdatedBuild() {
        XCTAssertEqual(LastUpdate.shownFor, 7 * 24 * 60 * 60)
        let update = update()

        XCTAssertTrue(update.isShown(runningBuild: 43, now: installedAt))
        XCTAssertTrue(update.isShown(runningBuild: 43, now: installedAt.addingTimeInterval(LastUpdate.shownFor - 1)))
        XCTAssertFalse(update.isShown(runningBuild: 43, now: installedAt.addingTimeInterval(LastUpdate.shownFor)))
        XCTAssertFalse(update.isShown(runningBuild: 44, now: installedAt), "gone after the next update")
        XCTAssertFalse(update.isShown(runningBuild: 42, now: installedAt), "gone after a rollback")
    }

    func testTheLastUpdateSurvivesTheRelaunchUntilTheNextOneReplacesIt() {
        let defaults = MemoryKeyValueStore()
        XCTAssertNil(LastUpdateStore(defaults: defaults).load())
        LastUpdateStore(defaults: defaults).save(update())

        // A later launch is a new process: a new store over the same UserDefaults. Reading doesn't forget it.
        let relaunched = LastUpdateStore(defaults: defaults)
        XCTAssertEqual(relaunched.load(), update())
        XCTAssertEqual(relaunched.shown(runningBuild: 43, now: installedAt.addingTimeInterval(60)), update())
        XCTAssertEqual(relaunched.load(), update())
        XCTAssertNil(relaunched.shown(runningBuild: 43, now: installedAt.addingTimeInterval(LastUpdate.shownFor)))

        let next = LastUpdate(version: "0.0.1.44", build: 44, details: ReleaseDetails(), installedAt: installedAt)
        relaunched.save(next)
        XCTAssertEqual(relaunched.load(), next)
        XCTAssertNil(relaunched.shown(runningBuild: 43, now: installedAt))

        relaunched.clear()
        XCTAssertNil(relaunched.load())
    }

    func testUnknownChangesAndPageAreKeptAsUnknown() {
        let defaults = MemoryKeyValueStore()
        let bare = LastUpdate(version: "0.0.1.43", build: 43, details: ReleaseDetails(), installedAt: installedAt)
        LastUpdateStore(defaults: defaults).save(bare)

        XCTAssertNil((defaults.values[LastUpdateStore.key] as? [String: Any])?["changes"])
        XCTAssertEqual(LastUpdateStore(defaults: defaults).load(), bare)
    }

    func testUnreadableLastUpdateIsIgnored() {
        let defaults = MemoryKeyValueStore()
        defaults.values[LastUpdateStore.key] = ["version": "0.0.1.43", "build": "43"]
        XCTAssertNil(LastUpdateStore(defaults: defaults).load())
        XCTAssertNil(LastUpdateStore(defaults: defaults).shown(runningBuild: 43))
    }

    // MARK: Menu line

    func testUpdatedLineNamesTheVersionAndTheChangeCountWhenKnown() {
        XCTAssertEqual(UpdateMenu.updatedLine(update()), "Updated to v0.0.1.43 (12 changes)")
        XCTAssertEqual(UpdateMenu.updatedLine(update(changes: 1)), "Updated to v0.0.1.43 (1 change)")
        XCTAssertEqual(UpdateMenu.updatedLine(update(changes: nil)), "Updated to v0.0.1.43")
    }

    func testTheUpdatedLineOpensTheInstalledReleasesNotes() throws {
        let outcome = try XCTUnwrap(UpdateOutcome(rolledBack: nil, lastUpdate: update()))
        XCTAssertEqual(outcome, .updated(update()))
        XCTAssertEqual(outcome.menuTitle, "Updated to v0.0.1.43 (12 changes)")
        XCTAssertNil(outcome.notesMessage)

        let release = try XCTUnwrap(outcome.release(latest: nil))
        XCTAssertEqual(release.version, "0.0.1.43")
        XCTAssertEqual(release.build, 43)
        XCTAssertEqual(release.notes, notes)
        XCTAssertEqual(release.pageURL, pageURL)
        XCTAssertEqual(UpdateMenu.releaseNotesHeading(release), "Symphony 0.0.1.43")
    }

    func testARollbackLineComesFirstAndOpensTheFailedVersionsNotesWithTheManualSteps() throws {
        let record = rollback(details: details())
        let outcome = try XCTUnwrap(UpdateOutcome(rolledBack: record, lastUpdate: update()))
        XCTAssertEqual(outcome, .rolledBack(record))
        XCTAssertEqual(
            outcome.menuTitle,
            "v0.0.1.43 was rolled back: symphony check failed: Config error: workspaces.repo does not exist"
        )
        XCTAssertEqual(outcome.release(latest: nil)?.notes, notes)
        XCTAssertEqual(
            outcome.notesMessage,
            "v0.0.1.43 was rolled back: symphony check failed: Config error: workspaces.repo does not exist. "
                + "To roll back by hand, or to keep the app from installing a version again, choose "
                + "Open Rollback Steps."
        )
        XCTAssertEqual(UpdateMenu.rollbackStepsTitle, "Open Rollback Steps")
        XCTAssertEqual(UpdateMenu.rollbackStepsURL.fragment, "rollback")
        XCTAssertTrue(UpdateMenu.rollbackStepsURL.path.hasSuffix("/macos/README.md"))
    }

    func testNoLineWithoutAnUpdateOrARollback() {
        XCTAssertNil(UpdateOutcome(rolledBack: nil, lastUpdate: nil))
    }

    func testARecordWithoutTheReleasesPageFallsBackToTheSameBuildFromTheLastCheck() {
        let latest = Release(version: "0.0.1.43", build: 43, notes: notes, pageURL: pageURL, changes: 12)
        let outcome = UpdateOutcome.rolledBack(rollback())

        XCTAssertEqual(outcome.release(latest: latest), latest)
        XCTAssertNil(outcome.release(latest: nil), "nothing to open: the line is disabled")
        let newer = Release(version: "0.0.1.44", build: 44, notes: "", pageURL: pageURL, changes: nil)
        XCTAssertNil(outcome.release(latest: newer), "another release's notes are never shown")
    }

    // MARK: Notifications

    func testUpdatedNotificationNamesTheNewVersionAndItsChanges() {
        XCTAssertEqual(
            UpdateNotice.updated(update()),
            UpdateNotice(
                title: "Symphony updated to v0.0.1.43",
                body: "12 changes. Choose Updated to v0.0.1.43 in the menu for the release notes."
            )
        )
        XCTAssertTrue(UpdateNotice.updated(update(changes: 1)).body.hasPrefix("1 change. "))
        XCTAssertEqual(
            UpdateNotice.updated(update(changes: nil)).body,
            "Choose Updated to v0.0.1.43 in the menu for the release notes."
        )
    }

    func testRollbackNotificationNamesTheRestoredVersionTheFailedOneAndWhy() {
        XCTAssertEqual(
            UpdateNotice.rolledBack(rollback(), restoredVersion: "0.0.1.42"),
            UpdateNotice(
                title: "Symphony rolled back to v0.0.1.42",
                body: "v0.0.1.43 failed its health check (symphony check failed: Config error: workspaces.repo does "
                    + "not exist). It won't be installed by itself again; choose Retry v0.0.1.43 in the menu to "
                    + "install it."
            )
        )
        XCTAssertEqual(
            UpdateNotice.rolledBack(rollback(), restoredVersion: nil).title,
            "Symphony rolled back v0.0.1.43"
        )
    }

    func testFailedRollbackNotificationSaysHowToRollBackByHand() {
        let reason = "Symphony didn't answer within 120 seconds of starting; see ~/Library/Logs/Symphony/symphony.log"
        let notice = UpdateNotice.rollbackFailed(version: "0.0.1.43", reason: reason, problem: .noPreviousApp)

        XCTAssertEqual(notice.title, "Symphony couldn't roll back v0.0.1.43")
        XCTAssertEqual(
            notice.body,
            UpdateMenu.rollbackFailedLine(version: "0.0.1.43", reason: reason, problem: .noPreviousApp)
        )
    }
}
