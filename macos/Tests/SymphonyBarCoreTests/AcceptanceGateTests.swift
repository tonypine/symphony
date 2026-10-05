import XCTest
@testable import SymphonyBarCore

final class AcceptanceGateTests: XCTestCase {
    /// A config with the gate block, comments inside it, and two repositories, one with its own mode.
    private let config = """
        # Symphony operator config.
        auto_review:
          runtime: claude
          acceptance_gate:
            # The kill switch.
            mode: shadow  # enforce once the stats say ready
            max_turns: 12

        repositories:
          - key: symphony
            default: true
            workspace:
              repo: ~/Projects/symphony
            acceptance_gate:
              mode: enforce  # trusted
              escalate:
                paths:
                  - lib/symphony_elixir/auto_review.ex

          - key: my_web
            route:
              labels: [web]

        """

    // MARK: Modes

    func testModesReadOnlyTheValuesSymphonyAccepts() {
        XCTAssertEqual(AcceptanceGateMode(value: "enforce"), .enforce)
        XCTAssertNil(AcceptanceGateMode(value: "Enforce"))
        XCTAssertNil(AcceptanceGateMode(value: nil))
        XCTAssertEqual(AcceptanceGateMode.allCases.map(\.title), ["Off", "Shadow", "Enforce"])
        XCTAssertTrue(AcceptanceGateMode.off.explanation.hasPrefix("The gate never runs."))
        XCTAssertTrue(AcceptanceGateMode.shadow.explanation.hasPrefix("The gate records a verdict and moves nothing."))
        XCTAssertTrue(AcceptanceGateMode.enforce.explanation.contains("approve to Merging, rework back to In Progress, escalate to In Review"))
    }

    func testAChoiceInheritsOrNamesAMode() {
        XCTAssertEqual(AcceptanceGateChoice(override: nil), .inherit)
        XCTAssertEqual(AcceptanceGateChoice(override: "shadow"), .mode(.shadow))
        XCTAssertEqual(AcceptanceGateChoice(override: "loud"), .inherit)
        XCTAssertNil(AcceptanceGateChoice.inherit.override)
        XCTAssertEqual(AcceptanceGateChoice.mode(.off).override, "off")
        XCTAssertEqual(AcceptanceGateChoice.allCases.map(\.id), ["inherit", "off", "shadow", "enforce"])
        XCTAssertEqual(
            AcceptanceGateChoice.allCases.map { $0.title(inheriting: .shadow) },
            ["Inherit (Shadow)", "Off", "Shadow", "Enforce"]
        )
        XCTAssertEqual(AcceptanceGateChoice.inherit.explanation(inheriting: .shadow), "Follows the mode in Settings, now Shadow.")
        XCTAssertEqual(AcceptanceGateChoice.mode(.off).explanation(inheriting: .shadow), AcceptanceGateMode.off.explanation)
        XCTAssertEqual(AcceptanceGateChoice.inherit.effective(inheriting: .enforce), .enforce)
        XCTAssertEqual(AcceptanceGateChoice.mode(.off).effective(inheriting: .enforce), .off)
    }

    func testOnlyAMoveIntoEnforceAsksFirst() {
        XCTAssertTrue(AcceptanceGate.needsConfirmation(from: .off, to: .enforce))
        XCTAssertTrue(AcceptanceGate.needsConfirmation(from: .shadow, to: .enforce))
        XCTAssertFalse(AcceptanceGate.needsConfirmation(from: .enforce, to: .enforce))
        XCTAssertFalse(AcceptanceGate.needsConfirmation(from: .enforce, to: .off))
        XCTAssertFalse(AcceptanceGate.needsConfirmation(from: .off, to: .shadow))
        XCTAssertTrue(AcceptanceGate.confirmMessage.hasPrefix("PRs the gate approves merge without a person reviewing them"))
    }

    // MARK: Global key

    func testReadsTheGlobalMode() throws {
        XCTAssertEqual(try AcceptanceGate.globalMode(in: config), .shadow)
        XCTAssertEqual(try AcceptanceGate.globalMode(in: "auto_review:\n  acceptance_gate:\n    mode: \"off\"\n"), .off)
        XCTAssertEqual(try AcceptanceGate.globalMode(in: "auto_review:\n  acceptance_gate:\n    mode: 'enforce'\n"), .enforce)
    }

    func testAMissingOrEmptyGlobalModeReadsAsOff() throws {
        XCTAssertEqual(try AcceptanceGate.globalMode(in: "issues:\n  provider: linear\n"), .off)
        XCTAssertEqual(try AcceptanceGate.globalMode(in: "auto_review:\n  runtime: claude\n"), .off)
        XCTAssertEqual(try AcceptanceGate.globalMode(in: "auto_review:\n  acceptance_gate:\n    max_turns: 4\n"), .off)
        XCTAssertEqual(try AcceptanceGate.globalMode(in: "auto_review:\n  acceptance_gate:\n    mode:\n"), .off)
    }

    func testAGlobalModeSymphonyRejectsFailsToRead() {
        XCTAssertThrowsError(try AcceptanceGate.globalMode(in: "auto_review:\n  acceptance_gate:\n    mode: loud\n")) { error in
            XCTAssertEqual(error as? AcceptanceGateConfigError, .unknownMode("loud"))
            XCTAssertEqual(
                error.localizedDescription,
                "auto_review.acceptance_gate.mode is `loud`, which Symphony rejects. Set it to off, shadow or enforce."
            )
        }
    }

    func testAnInlineSectionFailsToReadAndWrite() {
        let inline = "auto_review: { acceptance_gate: { mode: shadow } }\n"
        XCTAssertThrowsError(try AcceptanceGate.globalMode(in: inline)) { error in
            XCTAssertEqual(error as? AcceptanceGateConfigError, .notABlock("auto_review"))
            XCTAssertTrue(error.localizedDescription.contains("Change the acceptance gate's mode by hand"))
        }
        XCTAssertThrowsError(try AcceptanceGate.settingGlobalMode(.off, in: inline))
        XCTAssertThrowsError(try AcceptanceGate.settingGlobalMode(.off, in: "auto_review:\n  acceptance_gate: {}\n")) { error in
            XCTAssertEqual(error as? AcceptanceGateConfigError, .notABlock("acceptance_gate"))
        }
    }

    func testSettingTheGlobalModeChangesOnlyItsValueAndKeepsComments() throws {
        let updated = try AcceptanceGate.settingGlobalMode(.enforce, in: config)
        XCTAssertEqual(
            updated,
            config.replacingOccurrences(
                of: "    mode: shadow  # enforce once the stats say ready",
                with: "    mode: enforce  # enforce once the stats say ready"
            )
        )
        XCTAssertEqual(try AcceptanceGate.globalMode(in: updated), .enforce)
        XCTAssertEqual(try AcceptanceGate.settingGlobalMode(.shadow, in: config), config)
    }

    func testOffIsWrittenQuotedAndReadsBack() throws {
        let updated = try AcceptanceGate.settingGlobalMode(.off, in: config)
        XCTAssertTrue(updated.contains("    mode: \"off\"  # enforce once the stats say ready\n"))
        XCTAssertEqual(try AcceptanceGate.globalMode(in: updated), .off)
        XCTAssertEqual(try AcceptanceGate.settingGlobalMode(.off, in: updated), updated)
        XCTAssertEqual(
            try AcceptanceGate.settingGlobalMode(.off, in: "auto_review:\n  acceptance_gate:\n    mode: off\n"),
            "auto_review:\n  acceptance_gate:\n    mode: off\n"
        )
    }

    func testSettingAnEmptyGlobalModeFillsItIn() throws {
        XCTAssertEqual(
            try AcceptanceGate.settingGlobalMode(.shadow, in: "auto_review:\n  acceptance_gate:\n    mode:  # pick one\n"),
            "auto_review:\n  acceptance_gate:\n    mode: shadow # pick one\n"
        )
    }

    func testSettingTheGlobalModeInsertsWhatIsMissing() throws {
        XCTAssertEqual(
            try AcceptanceGate.settingGlobalMode(.shadow, in: "# Config.\nissues:\n  provider: linear\n"),
            "# Config.\nissues:\n  provider: linear\nauto_review:\n  acceptance_gate:\n    mode: shadow\n"
        )
        XCTAssertEqual(
            try AcceptanceGate.settingGlobalMode(.shadow, in: "auto_review:\n    runtime: claude\n"),
            "auto_review:\n    acceptance_gate:\n        mode: shadow\n    runtime: claude\n"
        )
        XCTAssertEqual(
            try AcceptanceGate.settingGlobalMode(.enforce, in: "auto_review:\n  acceptance_gate:\n    # Defaults.\n    max_turns: 4\n"),
            "auto_review:\n  acceptance_gate:\n    mode: enforce\n    # Defaults.\n    max_turns: 4\n"
        )
        XCTAssertEqual(
            try AcceptanceGate.settingGlobalMode(.shadow, in: "auto_review:\n"),
            "auto_review:\n  acceptance_gate:\n    mode: shadow\n"
        )
        XCTAssertEqual(
            try AcceptanceGate.settingGlobalMode(.shadow, in: "auto_review:\n  acceptance_gate:\n"),
            "auto_review:\n  acceptance_gate:\n    mode: shadow\n"
        )
    }

    // MARK: Repository key

    func testReadsARepositorysOwnMode() throws {
        let entries = try RepositoriesConfig.entries(in: config)
        XCTAssertEqual(entries.map(\.acceptanceGateMode), ["enforce", nil])
    }

    func testSettingARepositorysModeChangesOnlyItsValue() throws {
        let updated = try AcceptanceGate.settingRepositoryMode(.mode(.off), of: "symphony", in: config)
        XCTAssertEqual(
            updated,
            config.replacingOccurrences(of: "      mode: enforce  # trusted", with: "      mode: \"off\"  # trusted")
        )
        XCTAssertEqual(try RepositoriesConfig.entries(in: updated).first?.acceptanceGateMode, "off")
    }

    func testInheritRemovesTheKeyAndKeepsTheRestOfTheBlock() throws {
        let updated = try AcceptanceGate.settingRepositoryMode(.inherit, of: "symphony", in: config)
        XCTAssertEqual(updated, config.replacingOccurrences(of: "      mode: enforce  # trusted\n", with: ""))
        XCTAssertNil(try RepositoriesConfig.entries(in: updated).first?.acceptanceGateMode)
    }

    func testInheritRemovesABlockItLeavesEmpty() throws {
        let set = try AcceptanceGate.settingRepositoryMode(.mode(.enforce), of: "my_web", in: config)
        XCTAssertTrue(set.contains("      labels: [web]\n    acceptance_gate:\n      mode: enforce\n"))
        XCTAssertEqual(try RepositoriesConfig.entries(in: set).last?.acceptanceGateMode, "enforce")
        XCTAssertEqual(try AcceptanceGate.settingRepositoryMode(.inherit, of: "my_web", in: set), config)
        XCTAssertEqual(try AcceptanceGate.settingRepositoryMode(.inherit, of: "my_web", in: config), config)
    }

    func testSettingAnUnknownRepositoryFails() {
        XCTAssertThrowsError(try AcceptanceGate.settingRepositoryMode(.mode(.off), of: "api", in: config)) { error in
            XCTAssertEqual(error as? RepositoriesConfigError, .notFound("api"))
        }
    }

    func testTheEditSheetSetsAndClearsTheRepositorysMode() throws {
        let entries = try RepositoriesConfig.entries(in: config)
        let symphony = entries[0]
        var draft = EditRepo.draft(for: symphony)
        XCTAssertEqual(draft.acceptanceGate, .mode(.enforce))

        draft.acceptanceGate = .inherit
        guard case let .success(cleared) = EditRepo.entry(for: draft, editing: symphony, existing: entries) else {
            return XCTFail("expected an entry")
        }
        XCTAssertNil(cleared.acceptanceGateMode)
        XCTAssertTrue(EditRepo.changesAcceptanceGate(from: symphony, to: cleared))
        XCTAssertNil(EditRepo.apply(status: .stopped, from: symphony, to: cleared))
        XCTAssertFalse(try RepositoriesConfig.updating("symphony", to: cleared, in: config).contains("mode: enforce"))

        draft.acceptanceGate = .mode(.shadow)
        guard case let .success(shadow) = EditRepo.entry(for: draft, editing: symphony, existing: entries) else {
            return XCTFail("expected an entry")
        }
        XCTAssertEqual(shadow.acceptanceGateMode, "shadow")
    }

    func testTheEditSheetKeepsAValueSymphonyRejectsUntilThePickerMoves() throws {
        let entries = try RepositoriesConfig.entries(in: config.replacingOccurrences(of: "mode: enforce", with: "mode: loud"))
        let draft = EditRepo.draft(for: entries[0])
        XCTAssertEqual(draft.acceptanceGate, .inherit)
        guard case let .success(entry) = EditRepo.entry(for: draft, editing: entries[0], existing: entries) else {
            return XCTFail("expected an entry")
        }
        XCTAssertEqual(entry.acceptanceGateMode, "loud")
        XCTAssertFalse(EditRepo.changesAcceptanceGate(from: entries[0], to: entry))
    }

    // MARK: Files

    func testWritesTheFileKeepingItsComments() async throws {
        let directory = uniqueTemporaryDirectory("gate")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("symphony.yml")
        try Data(config.utf8).write(to: url)
        let file = SymphonyConfigFile(path: url.path)

        XCTAssertEqual(try file.readAcceptanceGateMode(), .shadow)
        var checked: String?
        let result = try await file.writeAcceptanceGateMode(.enforce) { path in
            checked = try? String(contentsOfFile: path, encoding: .utf8)
            return .passed
        }
        XCTAssertEqual(result, .passed)
        XCTAssertEqual(checked.flatMap { try? AcceptanceGate.globalMode(in: $0) }, .enforce)
        XCTAssertEqual(try file.readAcceptanceGateMode(), .enforce)
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("    # The kill switch.\n    mode: enforce  #"))

        let rejected = try await file.writeAcceptanceGateMode(.off) { _ in .failed("bad") }
        XCTAssertEqual(rejected, .failed("bad"))
        XCTAssertEqual(try file.readAcceptanceGateMode(), .enforce)

        try file.writeAcceptanceGateMode(.off)
        XCTAssertEqual(try file.readAcceptanceGateMode(), .off)

        try file.writeRepositoryAcceptanceGateMode(.mode(.off), of: "symphony")
        XCTAssertEqual(try file.readRepositories().first?.acceptanceGateMode, "off")
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("      mode: \"off\"  # trusted\n"))
    }

    // MARK: Agreement stats

    private let notReady = StateSnapshot.GateAgreement(
        judged: 12, agreed: 11, agreementRate: 0.917, unsafeApprovals: 0, falseReworks: 0, escalations: 0,
        readyToEnforce: false, unmetCondition: "at least 20 judged tickets (12 so far)"
    )

    func testTheStatsLine() {
        XCTAssertEqual(
            AcceptanceGate.agreementLine(notReady),
            "12 judged · 92% agreement · 0 unsafe approvals · not ready: at least 20 judged tickets (12 so far)"
        )
        let ready = StateSnapshot.GateAgreement(judged: 24, agreed: 23, agreementRate: 0.958, readyToEnforce: true)
        XCTAssertEqual(AcceptanceGate.agreementLine(ready), "24 judged · 96% agreement · 0 unsafe approvals · ready to enforce")
        let unsafe = StateSnapshot.GateAgreement(judged: 3, agreementRate: nil, unsafeApprovals: 1)
        XCTAssertEqual(
            AcceptanceGate.agreementLine(unsafe),
            "3 judged · no agreement yet · 1 unsafe approval · not ready: unknown"
        )
        XCTAssertEqual(AcceptanceGate.agreementLine(nil), "No verdicts decided by a person yet.")
    }

    func testTheLineOfARepository() {
        let snapshot = StateSnapshot(gateAgreement: ["symphony": notReady])
        XCTAssertEqual(AcceptanceGate.agreementLine(for: "symphony", in: snapshot), AcceptanceGate.agreementLine(notReady))
        XCTAssertEqual(AcceptanceGate.agreementLine(for: "web", in: snapshot), AcceptanceGate.noRecordLine)
        XCTAssertEqual(AcceptanceGate.agreementLine(for: "symphony", in: nil), "Start Symphony to see the gate's record.")
        XCTAssertEqual(AcceptanceGate.agreementLine(for: "symphony", in: StateSnapshot()), AcceptanceGate.unsupportedLine)
    }

    func testSettingsLinesListEachRepository() {
        let snapshot = StateSnapshot(gateAgreement: ["symphony": notReady, "api": notReady])
        XCTAssertEqual(
            AcceptanceGate.agreementLines(keys: ["web", "symphony"], in: snapshot),
            [
                "web: No verdicts decided by a person yet.",
                "symphony: \(AcceptanceGate.agreementLine(notReady))",
                "api: \(AcceptanceGate.agreementLine(notReady))",
            ]
        )
        XCTAssertEqual(AcceptanceGate.agreementLines(keys: [], in: StateSnapshot(gateAgreement: [:])), [AcceptanceGate.noRecordLine])
        XCTAssertEqual(AcceptanceGate.agreementLines(keys: ["web"], in: nil), [AcceptanceGate.notRunningLine])
        XCTAssertEqual(AcceptanceGate.agreementLines(keys: ["web"], in: StateSnapshot()), [AcceptanceGate.unsupportedLine])
    }

    func testDecodesTheAgreementFromTheState() throws {
        let json = """
            {"counts": {"running": 0},
             "acceptance_gate": {"running": [], "queued": [], "recent": [],
               "agreement": {"my_repo": {"judged": 12, "agreed": 11, "agreement_rate": 0.917, "unsafe_approvals": 0,
                 "false_reworks": 0, "escalations": 0, "escalations_merged_unchanged": 0,
                 "tokens": {"median": 1000, "p90": null}, "ready_to_enforce": false,
                 "unmet_condition": "at least 20 judged tickets (12 so far)"}}}}
            """
        guard case let .state(snapshot) = SymphonyState.poll(data: Data(json.utf8), statusCode: 200) else {
            return XCTFail("expected a state")
        }
        XCTAssertEqual(snapshot.gateAgreement, ["my_repo": notReady])

        guard case let .state(older) = SymphonyState.poll(data: Data(#"{"counts": {"running": 0}}"#.utf8), statusCode: 200) else {
            return XCTFail("expected a state")
        }
        XCTAssertNil(older.gateAgreement)

        let sparse = #"{"counts": {"running": 0}, "acceptance_gate": {"agreement": {"web": {}}}}"#
        guard case let .state(partial) = SymphonyState.poll(data: Data(sparse.utf8), statusCode: 200) else {
            return XCTFail("expected a state")
        }
        XCTAssertEqual(partial.gateAgreement, ["web": StateSnapshot.GateAgreement()])
    }

    // MARK: Menu and rows

    func testTheMenuListsEachRepositoryTheGateRunsOn() throws {
        let entries = try RepositoriesConfig.entries(in: config)
        let items = AcceptanceGate.menuItems(global: .shadow, entries: entries)
        XCTAssertEqual(items, [.init(key: "symphony", mode: .enforce), .init(key: "my_web", mode: .shadow)])
        XCTAssertEqual(items.map(\.title), ["Acceptance gate: Enforce (symphony)", "Acceptance gate: Shadow (my_web)"])
        XCTAssertEqual(AcceptanceGate.MenuItem.choices, [.shadow, .off])
        XCTAssertEqual(AcceptanceGate.menuItems(global: .off, entries: entries), [.init(key: "symphony", mode: .enforce)])
    }

    func testWithoutRepositoriesTheMenuShowsTheGlobalMode() {
        XCTAssertEqual(AcceptanceGate.menuItems(global: .off, entries: []), [])
        let items = AcceptanceGate.menuItems(global: .enforce, entries: [])
        XCTAssertEqual(items, [.init(key: nil, mode: .enforce)])
        XCTAssertEqual(items.first?.title, "Acceptance gate: Enforce")
    }

    func testTheKillSwitchMovesARepositoryFromEnforceToOff() throws {
        let updated = try AcceptanceGate.settingRepositoryMode(.mode(.off), of: "symphony", in: config)
        let entries = try RepositoriesConfig.entries(in: updated)
        XCTAssertEqual(AcceptanceGate.menuItems(global: .shadow, entries: entries), [.init(key: "my_web", mode: .shadow)])
    }

    func testARowShowsTheModeWhenItDiffersFromTheGlobalOne() throws {
        let entries = try RepositoriesConfig.entries(in: config)
        XCTAssertEqual(AcceptanceGate.repoField(entries[0], global: .shadow), RepoField("Gate", "Enforce"))
        XCTAssertNil(AcceptanceGate.repoField(entries[0], global: .enforce))
        XCTAssertNil(AcceptanceGate.repoField(entries[1], global: .shadow))
        let loud = RepositoryEntry(key: "x", acceptanceGateMode: "loud")
        XCTAssertEqual(AcceptanceGate.repoField(loud, global: .off)?.tone, .problem)
        XCTAssertEqual(AcceptanceGate.repoField(loud, global: .off)?.value, "loud")
    }

    func testTheReposWindowAddsTheGateFieldToRowsThatDiffer() throws {
        let entries = try RepositoriesConfig.entries(in: config)
        let display = ReposDisplay(notice: "n", rows: entries.map(ReposList.row) + [RepoRow(key: "api", isDefault: false, fields: [])])
        let shown = AcceptanceGate.withGateFields(display, entries: entries, global: .shadow)
        XCTAssertEqual(shown.rows[0].fields.last, RepoField("Gate", "Enforce"))
        XCTAssertEqual(shown.rows[0].fields.count, display.rows[0].fields.count + 1)
        XCTAssertEqual(shown.rows[1], display.rows[1])
        XCTAssertEqual(shown.rows[2], display.rows[2])
        XCTAssertEqual(AcceptanceGate.withGateFields(display, entries: entries, global: .enforce), display)
    }
}
