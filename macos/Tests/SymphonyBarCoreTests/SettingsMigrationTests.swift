import XCTest
@testable import SymphonyBarCore

final class SettingsMigrationTests: XCTestCase {
    private let rename = ReleaseSettingsMigration(key: "pre_push_review", to: "code_review")
    private let nested = ReleaseSettingsMigration(key: "repositories[].agent.run_profiles.pre_push_review", to: "code_review")
    private let removal = ReleaseSettingsMigration(key: "ledger.artifact_retention_days", to: nil)

    private let release = Release(
        version: "0.0.1.700",
        build: 700,
        notes: "",
        pageURL: URL(string: "https://github.com/tonypine/symphony/releases/tag/v0.0.1.700")!,
        changes: nil
    )

    func testPreviewFindsATopLevelKeyAndNothingElse() {
        XCTAssertEqual(SettingsMigrationPreview.affecting([rename], text: "pre_push_review:\n  enabled: true\n"), [rename])
        XCTAssertEqual(SettingsMigrationPreview.affecting([rename], text: "code_review:\n  enabled: true\n"), [])
        XCTAssertEqual(SettingsMigrationPreview.affecting([rename], text: "# pre_push_review:\n"), [], "a comment isn't a key")
        XCTAssertEqual(
            SettingsMigrationPreview.affecting([rename], text: "agent:\n  pre_push_review: 1\n"),
            [],
            "the same name in another section isn't the key"
        )
        XCTAssertEqual(SettingsMigrationPreview.affecting([], text: "pre_push_review:\n"), [])
    }

    func testPreviewWalksListItems() {
        let indented = """
            repositories:
              - key: one
                workflow: WORKFLOW.md
              - key: two
                agent:
                  run_profiles:
                    pre_push_review:
                      model: gpt-5
            """
        let sameColumn = """
            repositories:
            - key: one
              agent:
                run_profiles:
                  pre_push_review:
                    model: gpt-5
            ledger:
              artifact_retention_days: 3
            """

        XCTAssertEqual(SettingsMigrationPreview.affecting([nested, removal], text: indented), [nested])
        XCTAssertEqual(SettingsMigrationPreview.affecting([nested, removal], text: sameColumn), [nested, removal])
    }

    func testPreviewIgnoresWhatIsNotAKeyLine() {
        let paths = SettingsMigrationPreview.keyPaths("url: http://a\nlist:\n  - plain\n  -bad: 1\nhttp://b\n-: 2\n")
        XCTAssertEqual(paths, ["url", "list"])
    }

    func testTheMenuLineSaysWhatTheUpdateDoesForYou() {
        XCTAssertEqual(
            UpdateMenu.migrationLine(release, migrating: [rename]),
            "Update to v0.0.1.700 available; it renames one setting in your file, done for you"
        )
        XCTAssertEqual(
            UpdateMenu.migrationLine(release, migrating: [rename, nested]),
            "Update to v0.0.1.700 available; it renames 2 settings in your file, done for you"
        )
        XCTAssertEqual(
            UpdateMenu.migrationLine(release, migrating: [removal]),
            "Update to v0.0.1.700 available; it changes one setting in your file, done for you"
        )
        XCTAssertNil(UpdateMenu.migrationLine(release, migrating: []))
    }

    func testTheConfirmationSaysItChecksAndMigrates() {
        let confirmation = UpdateMenu.confirmation(release, symphonyRunning: false, migrating: [rename])

        XCTAssertTrue(confirmation.contains("checks your settings with it"))
        XCTAssertTrue(confirmation.contains("It renames one setting in your file, done for you."))
        XCTAssertFalse(UpdateMenu.confirmation(release, symphonyRunning: false).contains("done for you"))
    }

    func testARollbackPutsTheFileBackAsItWas() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let config = folder.appendingPathComponent("symphony.yml")
        let backup = SettingsMigrationBackup.url(config: config, version: "0.0.1.700")
        XCTAssertEqual(backup.lastPathComponent, "symphony.yml.before-v0.0.1.700")

        try "code_review: {}\n".write(to: config, atomically: true, encoding: .utf8)
        XCTAssertFalse(SettingsMigrationBackup.restore(config: config, version: "0.0.1.700"), "this build migrated nothing")
        XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), "code_review: {}\n")

        try "pre_push_review: {}\n".write(to: backup, atomically: true, encoding: .utf8)
        XCTAssertTrue(SettingsMigrationBackup.restore(config: config, version: "0.0.1.700"))

        XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), "pre_push_review: {}\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path), "a Retry migrates it and backs it up again")
        let migrated = folder.appendingPathComponent("symphony.yml.after-v0.0.1.700")
        XCTAssertEqual(try String(contentsOf: migrated, encoding: .utf8), "code_review: {}\n", "edits since the update stay")
    }
}
