import XCTest
@testable import SymphonyBarCore

/// Automatically when released arms a verified release with Symphony instead of pausing dispatch (TP-1590).
final class UpdateArmingTests: XCTestCase {
    private typealias Effect = UpdateArming.Effect

    private let began = Date(timeIntervalSince1970: 1_000_000)
    private let runsTimeout: TimeInterval = 30 * 60

    private func release(_ build: Int) -> Release {
        Release(
            version: "0.0.1.\(build)",
            build: build,
            notes: "",
            pageURL: URL(string: "https://github.com/tonypine/symphony/releases/tag/v0.0.1.\(build)")!,
            changes: nil
        )
    }

    private func update(_ build: Int) -> PreparedUpdate {
        PreparedUpdate(
            release: release(build),
            appURL: URL(fileURLWithPath: "/tmp/updates/0.0.1.\(build)/app/Symphony.app"),
            symphonyBinary: "/tmp/updates/0.0.1.\(build)/app/Symphony.app/Contents/Resources/symphony"
        )
    }

    private func window(_ build: Int, _ phase: StateSnapshot.UpdateWindow.Phase = .waiting) -> StateSnapshot.UpdateWindow {
        StateSnapshot.UpdateWindow(version: "0.0.1.\(build)", phase: phase)
    }

    // MARK: Arming

    func testAVerifiedReleaseIsArmedWithSymphonyAndWaitsWithDispatchGoingOn() {
        var arming = UpdateArming()

        XCTAssertEqual(arming.verified(update(1053)), [.arm(version: "0.0.1.1053")])
        XCTAssertEqual(arming.waitingVersion, "0.0.1.1053")
        XCTAssertEqual(arming.build, 1053)
        XCTAssertEqual(arming.armed("0.0.1.1053", result: .done), [])

        // Symphony keeps dispatching while runs are active: nothing to do, no pause.
        let polled = arming.polled(window: window(1053), pauseVersion: nil, activity: .running(activeRuns: 3))
        XCTAssertEqual(polled, [])
        XCTAssertFalse(arming.swapping)
    }

    func testTheSwapStartsOnceSymphonyPausedForTheUpdateAndOnlyOnce() {
        var arming = UpdateArming()
        _ = arming.verified(update(1053))
        _ = arming.armed("0.0.1.1053", result: .done)

        let effects = arming.polled(window: window(1053, .holding), pauseVersion: "0.0.1.1053", activity: .running(activeRuns: 0))

        XCTAssertEqual(effects, [.swap(update(1053))])
        XCTAssertTrue(arming.swapping)
        XCTAssertNil(arming.waitingVersion, "the update no longer waits with dispatch on")
        XCTAssertEqual(arming.polled(window: window(1053, .holding), pauseVersion: "0.0.1.1053", activity: .running(activeRuns: 0)), [])
    }

    /// c4: builds published while an update waits replace it; the app restarts once, onto the newest.
    func testNewerBuildsPublishedWhileItWaitsReplaceItAndOnlyTheNewestIsInstalled() {
        var arming = UpdateArming()
        var swaps: [PreparedUpdate] = []
        func record(_ effects: [Effect]) {
            for case let .swap(update) in effects { swaps.append(update) }
        }

        record(arming.verified(update(1053)))
        _ = arming.armed("0.0.1.1053", result: .done)
        record(arming.polled(window: window(1053), pauseVersion: nil, activity: .running(activeRuns: 2)))

        XCTAssertEqual(arming.verified(update(1054)), [.arm(version: "0.0.1.1054")])
        _ = arming.armed("0.0.1.1054", result: .done)
        record(arming.polled(window: window(1054), pauseVersion: nil, activity: .running(activeRuns: 1)))

        XCTAssertEqual(arming.verified(update(1056)), [.arm(version: "0.0.1.1056")])
        XCTAssertEqual(arming.verified(update(1055)), [], "an older build verified late changes nothing")
        _ = arming.armed("0.0.1.1056", result: .done)

        // Symphony pauses for 1056, the build it has ready, once no run is active.
        record(arming.polled(window: window(1056, .holding), pauseVersion: "0.0.1.1056", activity: .running(activeRuns: 0)))
        arming.drainEnded(waitsAgain: false)

        XCTAssertEqual(swaps, [update(1056)], "one restart, onto the newest build, none in between")
        XCTAssertNil(arming.target)
    }

    func testAPauseForAnOlderBuildIsNotTheUpdatesMoment() {
        var arming = UpdateArming()
        _ = arming.verified(update(1053))
        _ = arming.armed("0.0.1.1053", result: .done)
        _ = arming.verified(update(1054))

        // Symphony still holds for 1053 while the arm of 1054 is under way: no swap onto the older build.
        XCTAssertEqual(arming.polled(window: window(1053, .holding), pauseVersion: "0.0.1.1053", activity: .running(activeRuns: 0)), [])
    }

    func testASymphonyThatForgotTheUpdateIsArmedAgainOncePerAnswer() {
        var arming = UpdateArming()
        _ = arming.verified(update(1053))
        XCTAssertEqual(arming.polled(window: nil, pauseVersion: nil, activity: .running(activeRuns: 1)), [], "the arm is still under way")
        _ = arming.armed("0.0.1.1053", result: .done)

        // Symphony restarted and forgot it.
        XCTAssertEqual(arming.polled(window: nil, pauseVersion: nil, activity: .running(activeRuns: 1)), [.arm(version: "0.0.1.1053")])
        XCTAssertEqual(arming.polled(window: nil, pauseVersion: nil, activity: .running(activeRuns: 1)), [])
        XCTAssertEqual(arming.armed("0.0.1.1052", result: .done), [], "an answer for another version changes nothing")
    }

    func testASymphonyThatIsNotRunningSwapsAtOnceAndABusyOneWaits() {
        var arming = UpdateArming()
        _ = arming.verified(update(1053))
        XCTAssertEqual(arming.polled(window: nil, pauseVersion: nil, activity: .busy), [])
        XCTAssertEqual(arming.polled(window: nil, pauseVersion: nil, activity: .notRunning), [.swap(update(1053))])
        XCTAssertEqual(arming.verified(update(1054)), [], "the swap is under way")
    }

    func testASymphonyThatRefusesTheArmDrainsAsBeforeAfterThreeTries() {
        var arming = UpdateArming()
        _ = arming.verified(update(1053))

        XCTAssertEqual(arming.armed("0.0.1.1053", result: .failed("not found")), [])
        _ = arming.polled(window: nil, pauseVersion: nil, activity: .running(activeRuns: 1))
        XCTAssertEqual(arming.armed("0.0.1.1053", result: .failed("not found")), [])
        _ = arming.polled(window: nil, pauseVersion: nil, activity: .running(activeRuns: 1))
        XCTAssertEqual(arming.armed("0.0.1.1053", result: .failed("not found")), [.drain(update(1053))])
        XCTAssertTrue(arming.swapping)

        arming.drainEnded(waitsAgain: false)
        XCTAssertNil(arming.target, "a drain that didn't install waits for the next check")
    }

    func testSymphonyLiftingItsHoldSendsTheUpdateBackToWaiting() {
        var arming = UpdateArming()
        _ = arming.verified(update(1053))
        _ = arming.armed("0.0.1.1053", result: .done)
        _ = arming.polled(window: window(1053, .holding), pauseVersion: "0.0.1.1053", activity: .running(activeRuns: 2))

        arming.drainEnded(waitsAgain: true)

        XCTAssertEqual(arming.waitingVersion, "0.0.1.1053")
        XCTAssertEqual(arming.polled(window: window(1053), pauseVersion: nil, activity: .running(activeRuns: 2)), [])
        XCTAssertEqual(arming.verified(update(1054)), [.arm(version: "0.0.1.1054")])
    }

    func testCancelUpdateCallsTheUpdateOffOnSymphonysSideUnlessTheSwapAlreadyLiftsIt() {
        var arming = UpdateArming()
        XCTAssertEqual(arming.cancel(), [])
        arming.drainEnded(waitsAgain: true)

        _ = arming.verified(update(1053))
        XCTAssertEqual(arming.cancel(), [.disarm(version: "0.0.1.1053")])
        XCTAssertNil(arming.target)

        _ = arming.verified(update(1053))
        _ = arming.polled(window: nil, pauseVersion: "0.0.1.1053", activity: .running(activeRuns: 1))
        XCTAssertEqual(arming.cancel(), [], "the drain's own Cancel lifts Symphony's pause")
        XCTAssertNil(arming.target)
    }

    func testLeavingAutomaticallyWhenReleasedCallsOffTheUpdateSymphonyHasReady() {
        let skips = SkippedReleaseStore(defaults: MemoryKeyValueStore())
        var arming = UpdateArming()
        _ = arming.verified(update(1053))
        _ = arming.armed("0.0.1.1053", result: .done)
        XCTAssertEqual(arming.reconsider(mode: .onRelease, blocked: false, skips: skips), [])

        for mode in UpdateMode.allCases where mode != .onRelease {
            var other = arming
            XCTAssertEqual(other.reconsider(mode: mode, blocked: false, skips: skips), [.disarm(version: "0.0.1.1053")])
            XCTAssertNil(other.target)
            // Symphony's pause for that build is no longer the update's moment: nothing swaps in by itself.
            let polled = other.polled(window: window(1053, .holding), pauseVersion: "0.0.1.1053", activity: .running(activeRuns: 0))
            XCTAssertEqual(polled, [], "\(mode)")
        }

        var blocked = arming
        XCTAssertEqual(blocked.reconsider(mode: .onRelease, blocked: true, skips: skips), [.disarm(version: "0.0.1.1053")])
    }

    func testSkippingTheReleaseSymphonyHasReadyCallsItOffAndItNeverSwaps() {
        let skips = SkippedReleaseStore(defaults: MemoryKeyValueStore())
        var arming = UpdateArming()
        _ = arming.verified(update(1053))
        _ = arming.armed("0.0.1.1053", result: .done)

        // Skipping another build leaves it waiting.
        skips.record(SkippedRelease(release(1054), reason: .skipped))
        XCTAssertEqual(arming.reconsider(mode: .onRelease, blocked: false, skips: skips), [])

        skips.record(SkippedRelease(release(1053), reason: .skipped))
        XCTAssertEqual(arming.reconsider(mode: .onRelease, blocked: false, skips: skips), [.disarm(version: "0.0.1.1053")])
        XCTAssertNil(arming.waitingVersion)
        XCTAssertEqual(arming.polled(window: nil, pauseVersion: "0.0.1.1053", activity: .running(activeRuns: 0)), [])
    }

    func testOnceTheSwapStartedOnlyItsDrainCallsItOff() {
        let skips = SkippedReleaseStore(defaults: MemoryKeyValueStore())
        var arming = UpdateArming()
        _ = arming.verified(update(1053))
        _ = arming.polled(window: nil, pauseVersion: "0.0.1.1053", activity: .running(activeRuns: 0))

        XCTAssertEqual(arming.reconsider(mode: .manual, blocked: false, skips: skips), [])
        XCTAssertTrue(arming.swapping)
    }

    // MARK: The swap's drain

    private func swapDrain(running: Int = 1) -> (RestartMachine, [RestartMachine.Effect]) {
        var machine = RestartMachine()
        let effects = machine.begin(
            alreadyPaused: true,
            purpose: .armedUpdate,
            updatingTo: "0.0.1.1053",
            runsTimeout: runsTimeout,
            logPath: "~/Library/Logs/symphony/menubar-child.log",
            alerts: false,
            now: began
        )
        return (machine, effects)
    }

    private func held(running: Int) -> StatusPoll {
        .state(StateSnapshot(running: running, pause: .init(reason: "updating to v0.0.1.1053")))
    }

    func testTheSwapDrainsBehindSymphonysPauseAndNeverPausesOnItsOwn() {
        var (machine, effects) = swapDrain()
        XCTAssertEqual(effects, [.pollNow], "Symphony already paused for it")
        XCTAssertTrue(machine.purpose.isUpdate)
        XCTAssertTrue(machine.resumesDispatch, "a swap that fails after the stop lifts Symphony's pause")

        XCTAssertEqual(machine.handle(.polled(held(running: 1)), now: began), [])
        XCTAssertEqual(machine.menuLine(updatingTo: "0.0.1.1053", now: began), "Updating to v0.0.1.1053: waiting for 1 agent run…")
        XCTAssertEqual(machine.handle(.polled(held(running: 0)), now: began), [.stop])
        XCTAssertEqual(machine.handle(.exited(.signaled(15)), now: began), [.stopped])
    }

    func testSymphonyLiftingItsPauseEndsTheSwapQuietly() {
        var (machine, _) = swapDrain()

        let effects = machine.handle(.polled(.state(StateSnapshot(running: 2))), now: began)

        XCTAssertEqual(effects, [], "no pause of its own, no resume")
        XCTAssertFalse(machine.isRestarting)
        XCTAssertTrue(machine.released)
        XCTAssertNil(machine.error)
    }

    func testTheSwapOffersUpdateNowAnywayAndCancelLiftsSymphonysPause() {
        var (machine, _) = swapDrain()
        _ = machine.handle(.polled(held(running: 2)), now: began.addingTimeInterval(runsTimeout))
        XCTAssertTrue(machine.offersRestartNow)

        XCTAssertEqual(machine.handle(.cancel, now: began.addingTimeInterval(runsTimeout)), [.send(.resumeUpdate(version: "0.0.1.1053"))])
    }

    // MARK: What the app downloads meanwhile

    func testWhileAnUpdateIsArmedOnlyANewerReleaseIsDownloaded() {
        func context(_ build: Int, armed: Int?) -> AutoUpdater.Context {
            AutoUpdater.Context(
                mode: .onRelease,
                time: .defaultUpdateTime,
                offer: .available(release(build)),
                blocker: nil,
                activity: .running(activeRuns: 2),
                runsTimeout: runsTimeout,
                armedBuild: armed
            )
        }

        var updater = AutoUpdater()
        XCTAssertNil(updater.checked(.available(release(1053)), context(1053, armed: 1053)))
        XCTAssertEqual(updater.checked(.available(release(1056)), context(1056, armed: 1053)), .install(release(1056), kind: .onRelease))
    }

    // MARK: How it shows

    func testAnUpdateReadyShowsAsReadyWithDispatchGoingOn() {
        let hold = UpdateHold(release: release(1056), downloading: true, drain: RestartMachine(), ready: "0.0.1.1054")

        XCTAssertEqual(hold?.step, .ready, "a newer release downloading in the background doesn't hold anything")
        XCTAssertEqual(hold?.version, "0.0.1.1054")
        XCTAssertEqual(hold?.title, "v0.0.1.1054 ready")
        XCTAssertEqual(hold?.waitingLine, "Installs at the first moment no agent run is active")
        XCTAssertEqual(hold?.isReady, true)
        XCTAssertEqual(hold?.canCancel, true)
        XCTAssertEqual(UpdateHold(version: "0.0.1.1054", step: .stopping).canCancel, false)
        XCTAssertEqual(
            UpdateMenu.readyLine(version: "0.0.1.1054"),
            "v0.0.1.1054 is ready: it installs at the first moment no agent run is active."
        )
    }

    func testCancelUpdateOnAnUpdateReadyHoldsItsRelease() {
        let cancel = UpdateCancel(downloading: true, drain: RestartMachine(), kind: .onRelease, release: release(1056), ready: release(1054))

        XCTAssertEqual(cancel?.step, .ready)
        XCTAssertEqual(cancel?.hold, release(1054))
    }

    func testSymphonyReportsTheUpdateItHasReady() throws {
        let body = """
        {"counts": {"running": 2}, "update_window": {"version": "0.0.1.1056", "phase": "holding", "ready_at": "2026-11-21T14:17:02Z", "holding_since": null}}
        """
        guard case let .state(snapshot) = SymphonyState.poll(data: Data(body.utf8), statusCode: 200) else {
            return XCTFail("the state should parse")
        }
        XCTAssertEqual(snapshot.updateWindow?.version, "0.0.1.1056")
        XCTAssertEqual(snapshot.updateWindow?.phase, .holding)
        XCTAssertNotNil(snapshot.updateWindow?.readyAt)

        let none = """
        {"counts": {"running": 0}, "update_window": null}
        """
        guard case let .state(older) = SymphonyState.poll(data: Data(none.utf8), statusCode: 200) else {
            return XCTFail("the state should parse")
        }
        XCTAssertNil(older.updateWindow)
    }

    func testTheUpdateReadyRequest() throws {
        let action = ControlAction.updateReady(version: "0.0.1.1056")
        let request = ControlAPI.request(action, base: URL(string: "http://127.0.0.1:4010")!, token: "secret")

        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:4010/api/v1/control/update_ready")
        let body = try XCTUnwrap(request.httpBody)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: body) as? [String: String], ["version": "0.0.1.1056"])
        XCTAssertEqual(action.failurePrefix, "Couldn't tell Symphony v0.0.1.1056 is ready")
        XCTAssertNil(action.moveIdentifier)
        XCTAssertFalse(StatusMenu.isPause(action))
    }
}
