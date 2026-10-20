import XCTest
@testable import SymphonyBarCore

/// SU12: the first launch with setup errors opens Setup with a welcome line; and a repo added while Symphony was
/// stopped opens Setup at its start when it has an error (TP-911).
final class SetupOnStartTests: XCTestCase {
    private let checkedAt = ISO8601DateFormatter().date(from: "2026-10-20T06:00:00Z")

    private func running(_ problems: [SetupPayload.Problem], checked: Bool = true, external: Bool = false) -> SymphonyStatus {
        .running(StateSnapshot(setup: SetupPayload(problems: problems, checkedAt: checked ? checkedAt : nil)), external: external)
    }

    private func error(repos: [String] = []) -> SetupPayload.Problem {
        SetupPayload.Problem(id: "labels:missing:TP:Blocked", severity: .error, category: "labels", title: "No Blocked", consequence: "", repos: repos)
    }

    private let warning = SetupPayload.Problem(id: "deprecated_key:auto_review.enabled", severity: .warning, category: "keys", title: "Deprecated", consequence: "")

    /// The acceptance criterion: the first launch with an error opens Setup with the welcome line; without errors it
    /// doesn't; a later launch with errors doesn't.
    func testTheFirstLaunchOpensSetupOnlyWithErrors() {
        XCTAssertEqual(SetupOnStart.decide(firstRunRecorded: false, pendingRepos: [], status: running([error()])), .init(openSetup: true, welcome: true))
        XCTAssertEqual(SetupOnStart.decide(firstRunRecorded: false, pendingRepos: [], status: running([warning])), .init(openSetup: false))
        XCTAssertEqual(SetupOnStart.decide(firstRunRecorded: false, pendingRepos: [], status: running([])), .init(openSetup: false))
        XCTAssertNil(SetupOnStart.decide(firstRunRecorded: true, pendingRepos: [], status: running([error()])))
        // A Symphony started from the CLI is its first run on this Mac too, for the app.
        XCTAssertEqual(
            SetupOnStart.decide(firstRunRecorded: false, pendingRepos: [], status: running([error()], external: true)),
            .init(openSetup: true, welcome: true)
        )
        let paused = SymphonyStatus.paused(StateSnapshot(setup: SetupPayload(problems: [error()], checkedAt: checkedAt)), external: false)
        XCTAssertEqual(SetupOnStart.decide(firstRunRecorded: false, pendingRepos: [], status: paused), .init(openSetup: true, welcome: true))
        XCTAssertEqual(SetupOnStart.welcome.prefix(29), "Welcome to Symphony on this M")
    }

    /// Nothing is decided before Symphony answers with its first finished check.
    func testItWaitsForTheFirstCheck() {
        for status in [SymphonyStatus.stopped, .starting, .error("not answering")] {
            XCTAssertNil(SetupOnStart.decide(firstRunRecorded: false, pendingRepos: ["web"], status: status), "\(status)")
        }
        XCTAssertNil(SetupOnStart.decide(firstRunRecorded: false, pendingRepos: [], status: running([], checked: false)))
        // A Symphony that predates Setup settles everything, opening nothing.
        XCTAssertEqual(
            SetupOnStart.decide(firstRunRecorded: false, pendingRepos: ["web"], status: .running(StateSnapshot(), external: false)),
            .init(openSetup: false)
        )
    }

    /// A repo saved while Symphony was stopped opens Setup at the start when it, or the global setup, has an error.
    func testARepoAddedWhileStoppedOpensSetupWhenItHasAnError() {
        XCTAssertEqual(SetupOnStart.decide(firstRunRecorded: true, pendingRepos: ["web"], status: running([error(repos: ["web"])])), .init(openSetup: true))
        XCTAssertEqual(SetupOnStart.decide(firstRunRecorded: true, pendingRepos: ["web"], status: running([error()])), .init(openSetup: true))
        XCTAssertEqual(SetupOnStart.decide(firstRunRecorded: true, pendingRepos: ["web"], status: running([error(repos: ["api"])])), .init(openSetup: false))
        XCTAssertEqual(SetupOnStart.decide(firstRunRecorded: true, pendingRepos: ["web"], status: running([warning])), .init(openSetup: false))
    }

    /// The store records the first run and forgets the pending repos once a decision is made, so it is made once.
    func testTheStoreSettlesOnce() {
        let defaults = MemoryKeyValueStore()
        let store = SetupOnStartStore(defaults: defaults)
        XCTAssertFalse(store.firstRunRecorded)
        store.addPending("web")
        store.addPending("web")
        store.addPending("api")
        XCTAssertEqual(store.pendingRepos, ["web", "api"])

        XCTAssertNil(store.settle(status: .stopped))
        XCTAssertFalse(store.firstRunRecorded)
        XCTAssertEqual(store.settle(status: running([error(repos: ["web"])])), .init(openSetup: true, welcome: true))
        XCTAssertTrue(store.firstRunRecorded)
        XCTAssertEqual(store.pendingRepos, [])
        XCTAssertNil(store.settle(status: running([error(repos: ["web"])])))

        // Resetting the record (as QA does) brings the welcome back.
        defaults.set(nil, forKey: SetupOnStartStore.firstRunKey)
        XCTAssertEqual(SetupOnStartStore(defaults: defaults).settle(status: running([error()])), .init(openSetup: true, welcome: true))
    }
}
