import XCTest
@testable import SymphonyBarCore

final class UpdateHandoffTests: XCTestCase {
    private let pending = PendingUpdate(fromBuild: 42, toBuild: 43, version: "0.0.1.43", startSymphony: true, resumeDispatch: true)

    func testResumeAfterUpdateIsReadOnceAfterTheRelaunch() {
        let defaults = MemoryKeyValueStore()
        let store = PendingUpdateStore(defaults: defaults)
        XCTAssertNil(store.take(), "nothing is pending before an update")

        store.save(pending)
        // The relaunched app is a new process: a new store over the same UserDefaults.
        let relaunched = PendingUpdateStore(defaults: defaults)

        XCTAssertEqual(relaunched.take(), pending)
        XCTAssertNil(defaults.values[PendingUpdateStore.key])
        XCTAssertNil(relaunched.take(), "a later launch doesn't start Symphony or resume dispatch again")
    }

    func testClearForgetsAnUpdateThatDidNotHappen() {
        let store = PendingUpdateStore(defaults: MemoryKeyValueStore())
        store.save(pending)

        store.clear()

        XCTAssertNil(store.take())
    }

    func testUnreadableValueIsDropped() {
        let defaults = MemoryKeyValueStore()
        defaults.values[PendingUpdateStore.key] = ["toBuild": "43"]

        XCTAssertNil(PendingUpdateStore(defaults: defaults).take())
        XCTAssertNil(defaults.values[PendingUpdateStore.key])
    }

    func testCarriesTheReleaseAcrossTheRelaunch() {
        let defaults = MemoryKeyValueStore()
        let release = Release(
            version: "0.0.1.43",
            build: 43,
            notes: "12 changes since v0.0.1.42:\n- Fix",
            pageURL: URL(string: "https://github.com/tonypine/symphony/releases/tag/v0.0.1.43")!,
            changes: 12
        )
        let automatic = PendingUpdate(
            fromBuild: 42,
            toBuild: 43,
            version: "0.0.1.43",
            startSymphony: false,
            resumeDispatch: false,
            details: ReleaseDetails(release),
            automatic: true
        )
        PendingUpdateStore(defaults: defaults).save(automatic)

        let relaunched = PendingUpdateStore(defaults: defaults).take()
        XCTAssertEqual(relaunched, automatic)
        XCTAssertEqual(relaunched?.details.release(version: "0.0.1.43", build: 43), release)
    }

    func testReadsAPendingUpdateFromABuildThatDidNotKeepTheRelease() {
        let defaults = MemoryKeyValueStore()
        defaults.values[PendingUpdateStore.key] = [
            "fromBuild": 42, "toBuild": 43, "version": "0.0.1.43", "startSymphony": true, "resumeDispatch": true,
        ] as [String: Any]

        let relaunched = PendingUpdateStore(defaults: defaults).take()
        XCTAssertEqual(relaunched, pending)
        XCTAssertEqual(relaunched?.details, ReleaseDetails())
        XCTAssertEqual(relaunched?.automatic, false, "an update of unknown origin posts no notification")
        XCTAssertNil(relaunched?.details.release(version: "0.0.1.43", build: 43), "no page to open")
    }

    func testKeepsAPauseTheUserMade() {
        let store = PendingUpdateStore(defaults: MemoryKeyValueStore())
        let userPaused = PendingUpdate(fromBuild: 42, toBuild: 43, version: "0.0.1.43", startSymphony: true, resumeDispatch: false)

        store.save(userPaused)

        XCTAssertEqual(store.take()?.resumeDispatch, false)
    }

    func testRelaunchOfTheOldBuildMeansTheHelperRolledBack() {
        XCTAssertTrue(pending.succeeded(runningBuild: 43))
        XCTAssertFalse(pending.succeeded(runningBuild: 42))
        XCTAssertEqual(
            UpdateMenu.rolledBackMessage(pending, logPath: "~/Library/Caches/com.tonypine.symphony.bar/update-helper.log"),
            "The update to v0.0.1.43 couldn't replace the app, so this version was put back. "
                + "See ~/Library/Caches/com.tonypine.symphony.bar/update-helper.log."
        )
    }

    func testEligibility() {
        let release = AppBuild(build: 42, isDevelopment: false)
        func blocker(
            build: AppBuild = release,
            developmentMode: Bool = false,
            hasPublicKey: Bool = true,
            writable: Bool = true
        ) -> String? {
            UpdateEligibility.blocker(
                build: build,
                developmentMode: developmentMode,
                hasPublicKey: hasPublicKey,
                appLocationWritable: writable
            )
        }

        XCTAssertNil(blocker())
        XCTAssertEqual(blocker(build: AppBuild(build: 1, isDevelopment: true)), "Updates need a release build of Symphony.app")
        XCTAssertEqual(blocker(developmentMode: true), "Updates are off in Development mode")
        XCTAssertEqual(blocker(hasPublicKey: false), "This build has no update signing key")
        XCTAssertEqual(blocker(writable: false), "Move Symphony.app to a folder you can write to, such as ~/Applications")
    }

    func testHelperArgumentsKeepThePreviousAppNextToTheApp() {
        let app = URL(fileURLWithPath: "/Users/me/Applications/Symphony.app")
        let new = URL(fileURLWithPath: "/Users/me/Library/Caches/com.tonypine.symphony.bar/updates/0.0.1.43/app/Symphony.app")
        let script = URL(fileURLWithPath: "/Users/me/Library/Caches/com.tonypine.symphony.bar/update-helper.sh")

        XCTAssertEqual(UpdateHelper.previousAppURL(for: app).path, "/Users/me/Applications/Symphony (previous).app")
        XCTAssertEqual(
            UpdateHelper.arguments(script: script, pid: 123, currentApp: app, newApp: new),
            [script.path, "123", app.path, new.path, "/Users/me/Applications/Symphony (previous).app"]
        )
    }

    func testRollbackReversesTheSwapAndMovesTheFailedBuildAside() {
        let app = URL(fileURLWithPath: "/Users/me/Applications/Symphony.app")
        let script = URL(fileURLWithPath: "/Users/me/Library/Caches/com.tonypine.symphony.bar/update-helper.sh")

        XCTAssertEqual(UpdateHelper.rolledBackAppURL(for: app).path, "/Users/me/Applications/Symphony (rolled back).app")
        XCTAssertEqual(
            UpdateHelper.rollbackArguments(script: script, pid: 123, currentApp: app),
            [
                script.path, "123", app.path, "/Users/me/Applications/Symphony (previous).app",
                "/Users/me/Applications/Symphony (rolled back).app",
            ]
        )
        XCTAssertNotEqual(UpdateHelper.rollbackLogName, UpdateHelper.logName, "a rollback keeps the update's log")
    }

    func testMenuText() {
        let release = Release(
            version: "0.0.1.43",
            build: 43,
            notes: "",
            pageURL: URL(string: "https://github.com/tonypine/symphony/releases/tag/v0.0.1.43")!,
            changes: nil
        )

        XCTAssertEqual(UpdateMenu.installTitle(release), "Update to v0.0.1.43")
        XCTAssertEqual(UpdateMenu.preparingLine(release), "Updating: downloading and verifying v0.0.1.43…")
        XCTAssertTrue(UpdateMenu.confirmation(release, symphonyRunning: true).contains("waits for active agent runs"))
        XCTAssertFalse(UpdateMenu.confirmation(release, symphonyRunning: false).contains("agent runs"))
    }
}
