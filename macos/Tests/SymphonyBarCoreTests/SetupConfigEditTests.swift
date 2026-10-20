import XCTest
@testable import SymphonyBarCore

final class SetupConfigEditTests: XCTestCase {
    private let config = """
    # Symphony's config
    issues:
      provider: linear
    auto_review:
      enabled: true # retired
      acceptance_gate:
        escalate:
          labels: [human-action, "needs: eyes"]
    pull_requests:
      checks:
        escalate_to_state: Human Review
        required:
          - test
          - lint # style
    repositories:
      - key: web-shop
        workflow: WORKFLOW.md
        route:
          team: TQ
          projects: [a1abb875ac02]
    agent:
      runtime: claude

    """

    private func edit(_ path: String, _ action: SetupPayload.ConfigAction, _ value: SetupValue = .null, in yaml: String? = nil) throws -> String {
        try SetupConfigEdit.apply(path: path, action: action, value: value, to: yaml ?? config)
    }

    // MARK: - Remove a key

    func testRemoveTakesOutTheKeyAndLeavesTheRestAsItIs() throws {
        let edited = try edit("pull_requests.checks.escalate_to_state", .remove)
        XCTAssertEqual(edited, config.replacingOccurrences(of: "    escalate_to_state: Human Review\n", with: ""))
    }

    func testRemoveTakesASectionItEmptiesToo() throws {
        let yaml = "issues:\n  provider: linear\nauto_review:\n  enabled: true\n  # a note under it\nagent:\n  runtime: claude\n"
        XCTAssertEqual(try edit("auto_review.enabled", .remove, in: yaml), "issues:\n  provider: linear\nagent:\n  runtime: claude\n")
        XCTAssertEqual(try edit("agent", .remove, in: yaml), "issues:\n  provider: linear\nauto_review:\n  enabled: true\n  # a note under it\n")
    }

    func testRemoveKeepsTheSectionWhileItHasOtherKeys() throws {
        let edited = try edit("auto_review.enabled", .remove)
        XCTAssertEqual(edited, config.replacingOccurrences(of: "  enabled: true # retired\n", with: ""))
    }

    func testRemoveOfAMissingKeyFails() {
        XCTAssertThrowsError(try edit("auto_review.state", .remove)) { error in
            XCTAssertEqual(error as? SetupConfigEditError, .notFound("auto_review.state"))
            XCTAssertEqual(error.localizedDescription, "symphony.yml has no auto_review.state any more. Check Again to see whether the problem is gone.")
        }
        XCTAssertThrowsError(try edit("issues.provider.kind", .remove)) { error in
            XCTAssertEqual(error as? SetupConfigEditError, .unsupported("`provider:` holds an inline value, not an indented block"))
        }
        XCTAssertThrowsError(try edit("a..b", .remove))
        XCTAssertThrowsError(try edit("a[0].b", .remove))
    }

    // MARK: - Lists

    func testRemoveAnItemFromAFlowList() throws {
        let edited = try edit("auto_review.acceptance_gate.escalate.labels", .remove, .string("human-action"))
        XCTAssertEqual(edited, config.replacingOccurrences(of: "[human-action, \"needs: eyes\"]", with: "[\"needs: eyes\"]"))
        let quoted = try edit("auto_review.acceptance_gate.escalate.labels", .remove, .string("needs: eyes"))
        XCTAssertEqual(quoted, config.replacingOccurrences(of: "[human-action, \"needs: eyes\"]", with: "[human-action]"))
        XCTAssertThrowsError(try edit("auto_review.acceptance_gate.escalate.labels", .remove, .string("Blocked")))
    }

    func testRemoveAnItemFromABlockList() throws {
        let edited = try edit("pull_requests.checks.required", .remove, .string("lint"))
        XCTAssertEqual(edited, config.replacingOccurrences(of: "      - lint # style\n", with: ""))
        let both = try edit("pull_requests.checks.required", .remove, .string("test"), in: edited)
        XCTAssertEqual(both, config.replacingOccurrences(of: "    required:\n      - test\n      - lint # style\n", with: "    required: []\n"))
    }

    func testRemoveAScalarListOfOne() throws {
        let yaml = "labels: human-action\n"
        XCTAssertEqual(try edit("labels", .remove, .string("human-action"), in: yaml), "labels: []\n")
        XCTAssertThrowsError(try edit("labels", .remove, .string("other"), in: yaml))
        XCTAssertThrowsError(try edit("labels", .remove, .list([]), in: yaml))
        XCTAssertThrowsError(try edit("labels", .remove, .string("x"), in: "labels: [a, [b]]\n"))
        XCTAssertThrowsError(try edit("labels", .remove, .string("x"), in: "labels: [a,\n  b]\n"))
    }

    func testAddAnItem() throws {
        XCTAssertEqual(
            try edit("auto_review.acceptance_gate.escalate.labels", .add, .string("Blocked")),
            config.replacingOccurrences(of: "[human-action, \"needs: eyes\"]", with: "[human-action, \"needs: eyes\", Blocked]")
        )
        XCTAssertEqual(try edit("auto_review.acceptance_gate.escalate.labels", .add, .string("human-action")), config)
        XCTAssertEqual(
            try edit("pull_requests.checks.required", .add, .string("build")),
            config.replacingOccurrences(of: "      - lint # style\n", with: "      - lint # style\n      - build\n")
        )
        XCTAssertEqual(try edit("pull_requests.checks.required", .add, .string("test")), config)
        XCTAssertEqual(try edit("labels", .add, .string("b"), in: "labels: a\n"), "labels: [a, b]\n")
        XCTAssertEqual(try edit("labels", .add, .string("a"), in: "labels: a\n"), "labels: a\n")
        XCTAssertEqual(try edit("labels", .add, .string("a"), in: "labels:\nnext: 1\n"), "labels: [a]\nnext: 1\n")
        // A missing key goes in as the settings writer inserts one: first in its section.
        XCTAssertEqual(try edit("agent.labels", .add, .string("a"), in: "agent:\n  runtime: claude\n"), "agent:\n  labels: [a]\n  runtime: claude\n")
        XCTAssertThrowsError(try edit("labels", .add, .list([.string("a")]), in: "labels: a\n"))
    }

    // MARK: - Set

    func testSetAScalarOrAList() throws {
        XCTAssertEqual(try edit("issues.provider", .set, .string("memory")), config.replacingOccurrences(of: "provider: linear", with: "provider: memory"))
        XCTAssertEqual(try edit("auto_review.enabled", .set, .bool(false)), config.replacingOccurrences(of: "enabled: true # retired", with: "enabled: false # retired"))
        XCTAssertEqual(try edit("agent.max", .set, .number(3)), config.replacingOccurrences(of: "agent:\n", with: "agent:\n  max: 3\n"))
        XCTAssertEqual(
            try edit("pull_requests.checks.required", .set, .list([.string("test"), .string("a b")])),
            config.replacingOccurrences(of: "    required:\n      - test\n      - lint # style\n", with: "    required: [test, \"a b\"]\n")
        )
        XCTAssertThrowsError(try edit("issues.provider", .set, .null))
    }

    // MARK: - Repositories, through the Repos editor

    func testRepositoryFieldsGoThroughTheReposEditor() throws {
        let team = try edit("repositories[web-shop].route.team", .set, .string("TP"))
        XCTAssertEqual(team, config.replacingOccurrences(of: "team: TQ", with: "team: TP"))
        let projects = try edit("repositories[web-shop].route.projects", .add, .string("f92c-uuid"))
        XCTAssertEqual(projects, config.replacingOccurrences(of: "projects: [a1abb875ac02]", with: "projects: [a1abb875ac02, f92c-uuid]"))
        XCTAssertEqual(try edit("repositories[web-shop].route.projects", .add, .string("a1abb875ac02")), config)
        let replaced = try edit("repositories[web-shop].route.projects", .set, .list([.string("p-1")]))
        XCTAssertEqual(replaced, config.replacingOccurrences(of: "projects: [a1abb875ac02]", with: "projects: [p-1]"))
        XCTAssertEqual(try edit("repositories[web-shop].route.projects", .set, .string("p-2")), config.replacingOccurrences(of: "[a1abb875ac02]", with: "[p-2]"))
        let removedItem = try edit("repositories[web-shop].route.projects", .remove, .string("a1abb875ac02"))
        XCTAssertEqual(removedItem, config.replacingOccurrences(of: "projects: [a1abb875ac02]", with: "projects: []"))
        let removedList = try edit("repositories[web-shop].route.projects", .remove)
        XCTAssertEqual(removedList, config.replacingOccurrences(of: "      projects: [a1abb875ac02]\n", with: ""))
        let removedTeam = try edit("repositories[web-shop].route.team", .remove)
        XCTAssertEqual(removedTeam, config.replacingOccurrences(of: "      team: TQ\n", with: ""))
    }

    func testRepositoryEditsItCantMake() {
        XCTAssertThrowsError(try edit("repositories[docs].route.team", .set, .string("TP"))) { error in
            XCTAssertEqual(error as? SetupConfigEditError, .notFound("repository docs"))
        }
        XCTAssertThrowsError(try edit("repositories[web-shop].acceptance_gate.escalate.labels", .remove, .string("human-action"))) { error in
            XCTAssertEqual(error as? SetupConfigEditError, .unsupported("the Repos editor doesn't know acceptance_gate.escalate.labels"))
            XCTAssertEqual(
                error.localizedDescription,
                "The app can't make this change itself: the Repos editor doesn't know acceptance_gate.escalate.labels. Change it in symphony.yml by hand."
            )
        }
        XCTAssertThrowsError(try edit("repositories[web-shop].route.team", .add, .string("TP")))
        XCTAssertThrowsError(try edit("repositories[web-shop].route.team", .set, .list([])))
        XCTAssertThrowsError(try edit("repositories[web-shop].route.assignee", .remove))
        XCTAssertThrowsError(try edit("repositories[web-shop].route.labels", .remove))
        XCTAssertThrowsError(try edit("repositories[web-shop].route.labels", .remove, .string("x")))
        XCTAssertThrowsError(try edit("repositories[web-shop].route.labels", .set, .null))
        XCTAssertThrowsError(try edit("repositories[web-shop].route.labels", .add, .null))
        XCTAssertNil(SetupConfigEdit.repositoryPath("repositories.web-shop"))
        XCTAssertEqual(SetupConfigEdit.repositoryPath("repositories[a.b].route.team")?.key, "a.b")
    }

    // MARK: - Diff

    func testTheDiffShowsTheRemovedLinesWithContext() throws {
        let diff = SetupDiff(old: config, new: try edit("auto_review.enabled", .remove))
        XCTAssertEqual(diff.removed, ["  enabled: true # retired"])
        XCTAssertEqual(diff.added, [])
        XCTAssertEqual(diff.lines.map(\.marked), [
            "    provider: linear", "  auto_review:", "-   enabled: true # retired", "    acceptance_gate:", "      escalate:",
        ])
        XCTAssertEqual(diff.lines.first { $0.kind == .removed }?.number, 5)
        XCTAssertFalse(diff.isEmpty)
    }

    func testTheDiffJoinsFarChangesWithAGap() {
        let old = (1...12).map { "line \($0)" }.joined(separator: "\n")
        let new = old.replacingOccurrences(of: "line 2\n", with: "line two\n").replacingOccurrences(of: "line 11", with: "line eleven")
        let diff = SetupDiff(old: old, new: new, context: 1)
        XCTAssertEqual(diff.lines.map(\.marked), [
            "  line 1", "- line 2", "+ line two", "  line 3", "…", "  line 10", "- line 11", "+ line eleven", "  line 12",
        ])
        XCTAssertTrue(SetupDiff(old: old, new: old).isEmpty)
    }

    // MARK: - Through the settings writer, with a backup and Undo (AC 3)

    private func file(_ text: String, permissions: Int = 0o640) throws -> (SymphonyConfigFile, URL) {
        let directory = uniqueTemporaryDirectory("setup-config-fix")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("symphony.yml")
        try text.write(to: url, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return (SymphonyConfigFile(path: url.path), url)
    }

    private let date = ISO8601DateFormatter().date(from: "2026-10-19T23:35:12Z")!
    private let utc = TimeZone(identifier: "UTC")!

    func testARemoveFixBacksUpThenWritesTheExactEditAndUndoRestoresIt() async throws {
        let (file, url) = try file(config)
        let original = try Data(contentsOf: url)
        var checked: String?
        let result = try await file.applySetupFix({ try SetupConfigEdit.apply(path: "auto_review.enabled", action: .remove, value: .null, to: $0) }, at: date, timeZone: utc) { path in
            checked = try? String(contentsOfFile: path, encoding: .utf8)
            // The backup is there before the check runs.
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.deletingLastPathComponent().appendingPathComponent("symphony.yml.20261019-233512.bak").path))
            return .passed
        }

        guard case let .applied(backup) = result else { return XCTFail("not applied: \(result)") }
        let expected = config.replacingOccurrences(of: "  enabled: true # retired\n", with: "")
        XCTAssertEqual(checked, expected)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), expected)
        XCTAssertEqual(backup.url.lastPathComponent, "symphony.yml.20261019-233512.bak")
        XCTAssertEqual(try Data(contentsOf: backup.url), original)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int, 0o640)

        try backup.restore()
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int, 0o640)
    }

    func testARefusedFixWritesNothingAndKeepsNoBackup() async throws {
        let (file, url) = try file(config)
        let result = try await file.applySetupFix({ try SetupConfigEdit.apply(path: "auto_review.enabled", action: .remove, value: .null, to: $0) }, at: date, timeZone: utc) { _ in
            .failed("Config error in symphony.yml: bad")
        }
        XCTAssertEqual(result, .rejected("Config error in symphony.yml: bad"))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), config)
        XCTAssertEqual(SetupBackup.backups(of: url), [])
    }

    func testAnEditThatFailsOrChangesNothingWritesNothing() async throws {
        let (file, url) = try file(config)
        let unchanged = try await file.applySetupFix({ $0 }, at: date, timeZone: utc) { _ in .passed }
        XCTAssertEqual(unchanged, .unchanged)
        do {
            _ = try await file.applySetupFix({ try SetupConfigEdit.apply(path: "nope", action: .remove, value: .null, to: $0) }, at: date) { _ in .passed }
            XCTFail("no error")
        } catch {
            XCTAssertEqual(error as? SetupConfigEditError, .notFound("nope"))
        }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), config)
        XCTAssertEqual(SetupBackup.backups(of: url), [])
    }

    func testAWriteThatFailsRemovesTheBackup() async throws {
        let (file, url) = try file(config)
        var edits = 0
        do {
            _ = try await file.applySetupFix({ text in
                edits += 1
                // The writer reads the file again for its own edit: fail there, after the backup.
                if edits > 1 { throw SetupConfigEditError.unsupported("test") }
                return text + "x: 1\n"
            }, at: date, timeZone: utc) { _ in .passed }
            XCTFail("no error")
        } catch {
            XCTAssertEqual(error as? SetupConfigEditError, .unsupported("test"))
        }
        XCTAssertEqual(SetupBackup.backups(of: url), [])
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), config)
    }

    func testBackupsKeepTheLastTenAndNeverClash() throws {
        let (file, url) = try file(config)
        let directory = url.deletingLastPathComponent()
        try "other".write(to: directory.appendingPathComponent("symphony.yml.notes.bak"), atomically: false, encoding: .utf8)
        var made: [String] = []
        for second in 0..<12 {
            made.append(try SetupBackup.make(of: file, at: date.addingTimeInterval(TimeInterval(second)), timeZone: utc).url.lastPathComponent)
        }
        let again = try SetupBackup.make(of: file, at: date.addingTimeInterval(11), timeZone: utc)
        XCTAssertEqual(again.url.lastPathComponent, "symphony.yml.20261019-233523-2.bak")
        let kept = SetupBackup.backups(of: url).map(\.lastPathComponent)
        XCTAssertEqual(kept.count, SetupBackup.keep)
        XCTAssertEqual(kept.first, "symphony.yml.20261019-233515.bak")
        XCTAssertTrue(kept.contains("symphony.yml.20261019-233523-2.bak"))
        XCTAssertFalse(kept.contains(made[0]))
        // A file that isn't a backup is never pruned.
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("symphony.yml.notes.bak").path))

        let copy = try XCTUnwrap(SetupBackup.backups(of: url).last)
        let backup = SetupBackup(url: copy, original: url)
        backup.discard()
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
        XCTAssertThrowsError(try backup.restore())
    }

    func testABackupOfASymlinkedFileSitsNextToTheFile() throws {
        let directory = uniqueTemporaryDirectory("setup-config-link")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("real"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("real/symphony.yml")
        try config.write(to: target, atomically: false, encoding: .utf8)
        let link = directory.appendingPathComponent("symphony.yml")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let backup = try SetupBackup.make(of: SymphonyConfigFile(path: link.path), at: date, timeZone: utc)
        XCTAssertEqual(backup.url.deletingLastPathComponent().resolvingSymlinksInPath().path, target.deletingLastPathComponent().resolvingSymlinksInPath().path)
        XCTAssertEqual(SetupBackup.name(for: "symphony.yml", at: date, timeZone: utc), "symphony.yml.20261019-233512.bak")
    }

    func testTheSettingsPath() {
        XCTAssertNil(SymphonyConfigFile(settingsPath: "  "))
        let file = SymphonyConfigFile(settingsPath: "~/symphony/my.yml")
        XCTAssertEqual(file?.path, ("~/symphony/my.yml" as NSString).expandingTildeInPath)
        XCTAssertEqual(file?.fileName, "my.yml")
        XCTAssertNil(SymphonyConfigFile(path: "/nonexistent/symphony.yml").text())
    }

    /// The QA fixture's `symphony.yml`: Remove takes out `auto_review:` with its one key.
    func testTheQAFixtureLosesItsDeprecatedKey() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/director-app/setup/config/symphony.yml")
        let text = try String(contentsOf: url, encoding: .utf8)
        let edited = try SetupConfigEdit.apply(path: "auto_review.enabled", action: .remove, value: .null, to: text)
        XCTAssertEqual(edited, text.replacingOccurrences(of: "auto_review:\n  enabled: true\n", with: ""))
        XCTAssertEqual(text.components(separatedBy: "\n").firstIndex(of: "  enabled: true").map { $0 + 1 }, 10)
    }
}
