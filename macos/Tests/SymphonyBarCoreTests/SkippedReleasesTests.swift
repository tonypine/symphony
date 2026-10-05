import XCTest
@testable import SymphonyBarCore

final class SkippedReleasesTests: XCTestCase {
    private let current = AppBuild(build: 41, isDevelopment: false)

    private func release(build: Int = 42, changes: Int? = 12) -> Release {
        Release(
            version: "0.0.1.\(build)",
            build: build,
            notes: "",
            pageURL: URL(string: "https://github.com/tonypine/symphony/releases/tag/v0.0.1.\(build)")!,
            changes: changes
        )
    }

    func testAReleaseIsAvailableUntilSkipped() {
        let store = SkippedReleaseStore(defaults: MemoryKeyValueStore())

        let offer = UpdateOffer(release(), skips: store)

        XCTAssertEqual(offer, .available(release()))
        XCTAssertTrue(offer.offersSkip)
        XCTAssertEqual(offer.title(current: current), "Update available: v0.0.1.42 (12 changes)")
    }

    func testSkipThisVersionIsKeptAcrossRelaunches() {
        let defaults = MemoryKeyValueStore()
        SkippedReleaseStore(defaults: defaults).record(SkippedRelease(release(), reason: .skipped))
        // The relaunched app is a new process: a new store over the same UserDefaults.
        let relaunched = SkippedReleaseStore(defaults: defaults)

        let offer = UpdateOffer(release(), skips: relaunched)

        XCTAssertEqual(relaunched.entry(forBuild: 42), SkippedRelease(build: 42, version: "0.0.1.42", reason: .skipped))
        XCTAssertEqual(offer, .skipped(release(), .skipped))
        XCTAssertFalse(offer.offersSkip, "Skip This Version hides once the release is skipped")
        XCTAssertEqual(offer.release, release(), "Update to vX still installs it")
        XCTAssertEqual(offer.title(current: current), "Update skipped: v0.0.1.42 (12 changes)")
    }

    func testANewerReleaseThanTheSkippedOneIsOffered() {
        let store = SkippedReleaseStore(defaults: MemoryKeyValueStore())
        store.record(SkippedRelease(release(build: 42), reason: .skipped))

        XCTAssertEqual(UpdateOffer(release(build: 43), skips: store), .available(release(build: 43)))
        XCTAssertNil(store.entry(forBuild: 43))
        XCTAssertNil(store.entry(forBuild: 41), "a skip covers its build only, not every build up to it")
    }

    func testInstallingByHandClearsTheSkip() {
        let defaults = MemoryKeyValueStore()
        let store = SkippedReleaseStore(defaults: defaults)
        store.record(SkippedRelease(release(build: 42), reason: .skipped))
        store.record(SkippedRelease(release(build: 43), reason: .skipped))

        store.clear(build: 42)

        XCTAssertEqual(UpdateOffer(release(build: 42), skips: store), .available(release(build: 42)))
        XCTAssertNotNil(store.entry(forBuild: 43), "other skipped builds stay")
        store.clear(build: 43)
        XCTAssertNil(defaults.values[SkippedReleaseStore.key], "the key goes once nothing is skipped")
        store.clear(build: 44)
        XCTAssertNil(defaults.values[SkippedReleaseStore.key], "clearing a build that isn't skipped stores nothing")
    }

    func testTheStoreKeepsWhyABuildIsSkipped() {
        let defaults = MemoryKeyValueStore()
        let store = SkippedReleaseStore(defaults: defaults)
        store.record(SkippedRelease(release(), reason: .skipped))

        store.record(SkippedRelease(release(), reason: .rolledBack))

        let entry = SkippedReleaseStore(defaults: defaults).entry(forBuild: 42)
        XCTAssertEqual(entry?.reason, .rolledBack, "recording a build again replaces its reason")
        XCTAssertEqual(
            (defaults.values[SkippedReleaseStore.key] as? [String: Any])?["42"] as? [String: String],
            ["version": "0.0.1.42", "reason": "rolled back"]
        )
        let offer = UpdateOffer(release(changes: nil), skips: store)
        XCTAssertEqual(offer, .skipped(release(changes: nil), .rolledBack))
        XCTAssertEqual(offer.title(current: current), "Update rolled back: v0.0.1.42")
    }

    func testUnreadableEntriesAreNotSkips() {
        let defaults = MemoryKeyValueStore()
        defaults.values[SkippedReleaseStore.key] = [
            "42": ["version": "0.0.1.42", "reason": "ignored"],
            "43": ["reason": "skipped"],
            "44": "skipped",
        ]
        let store = SkippedReleaseStore(defaults: defaults)

        for build in [42, 43, 44, 45] {
            XCTAssertNil(store.entry(forBuild: build), "\(build)")
        }

        defaults.values[SkippedReleaseStore.key] = "not a dictionary"
        XCTAssertNil(store.entry(forBuild: 42))
        store.record(SkippedRelease(release(), reason: .skipped))
        XCTAssertEqual(store.entry(forBuild: 42)?.reason, .skipped, "an unreadable value is replaced")
    }

    func testSkippedTitleLabelsADevelopmentBuild() {
        XCTAssertEqual(
            UpdateMenu.skippedTitle(release(changes: 1), reason: .skipped, current: AppBuild(build: 1, isDevelopment: true)),
            "Update skipped: v0.0.1.42 (1 change) · development build"
        )
        XCTAssertEqual(UpdateMenu.skipTitle, "Skip This Version")
    }
}
