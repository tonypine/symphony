import XCTest
@testable import SymphonyBarCore

/// `SettingsUIManifest` lists exactly the `symphony.yml` keys the line editors write, so
/// `mix settings.ui_coverage` neither misses a key the app edits nor counts one it doesn't.
final class SettingsUIManifestTests: XCTestCase {
    /// Commands with `--model` / `--effort` and section keys, so saving models moves them as the app does.
    private let config = """
        # Symphony operator config.
        agent:
          command: claude --model claude-opus-5-5 --effort high  # flags
        pre_push_review:
          command: claude --model claude-haiku-4-5-20251001 --effort low
          model: claude-haiku-4-5-20251001
          effort: low
        auto_review:
          command: claude --model claude-sonnet-5-5 --effort medium
          model: claude-sonnet-5-5
          effort: medium
        repositories:
          - key: web
            workflow: WORKFLOW.md
        workspaces:
          root: ~/work

        """

    private let fullEntry = RepositoryEntry(
        key: "api",
        isDefault: true,
        baseBranch: "main",
        workflow: "api/WORKFLOW.md",
        route: RepositoryRoute(team: "ENG", projects: ["api"], labels: ["backend"], assignee: "me"),
        workspace: RepositoryWorkspace(strategy: "worktree", repo: "~/api", fetchBeforeDispatch: true)
    )

    func testTheListIsSortedAndHoldsEachKeyOnce() {
        XCTAssertEqual(SettingsUIManifest.keyPaths, SettingsUIManifest.keyPaths.sorted())
        XCTAssertEqual(Set(SettingsUIManifest.keyPaths).count, SettingsUIManifest.keyPaths.count)
    }

    func testEveryKeyTheEditorsWriteIsListedAndEveryListedKeyIsWritten() throws {
        var written = Set<String>()

        func record(_ name: String, _ edit: (String) throws -> String, from before: String) throws -> String {
            let after = try edit(before)
            let paths = writtenPaths(from: before, to: after)
            XCTAssertFalse(paths.isEmpty, "\(name) wrote nothing")
            for path in paths where !covers(path) {
                XCTFail("\(name) writes `\(path)`, which SettingsUIManifest.keyPaths doesn't list")
            }
            written.formUnion(paths)
            return after
        }

        var yaml = try record("adding a repository", { try RepositoriesConfig.adding(fullEntry, to: $0) }, from: config)
        var changed = fullEntry
        changed.isDefault = false
        changed.baseBranch = "develop"
        changed.workflow = "WORKFLOW.md"
        changed.route = RepositoryRoute(team: "OPS", projects: ["ops"], labels: ["infra"], assignee: "you")
        changed.workspace = RepositoryWorkspace(source: "acme/api", fetchBeforeDispatch: false)
        yaml = try record("updating a repository", { try RepositoriesConfig.updating("api", to: changed, in: $0) }, from: yaml)

        yaml = try record("setting the acceptance gate mode", { try AcceptanceGate.settingGlobalMode(.shadow, in: $0) }, from: yaml)
        yaml = try record("changing the acceptance gate mode", { try AcceptanceGate.settingGlobalMode(.enforce, in: $0) }, from: yaml)
        yaml = try record("setting a repository's gate mode", {
            try AcceptanceGate.settingRepositoryMode(.mode(.off), of: "api", in: $0)
        }, from: yaml)
        yaml = try record("inheriting the gate mode", { try AcceptanceGate.settingRepositoryMode(.inherit, of: "api", in: $0) }, from: yaml)

        let every = RunProfile(model: "claude-opus-5-5", effort: "max", provider: "anthropic")
        let profiles = RunProfiles(defaults: every, kinds: Dictionary(uniqueKeysWithValues: RunKind.allCases.map { ($0, every) }))
        let old = try RunProfilesConfig.scopedProfiles(in: yaml)
        let new = ScopedRunProfiles(global: profiles, repositories: ["web": profiles, "api": profiles], smallModel: "x/y")
        yaml = try record("saving models", { try RunProfilesConfig.updating($0, from: old, to: new) }, from: yaml)
        yaml = try record("clearing models", { try RunProfilesConfig.updating($0, from: new, to: ScopedRunProfiles()) }, from: yaml)

        yaml = try record("setting max concurrent agents", { try MaxConcurrentAgents.setting(3, in: $0) }, from: yaml)
        let limits = TokenLimits(perDay: .tokens(1_000), perIssue: .off)
        yaml = try record("setting token limits", { try TokenLimits.updating($0, from: TokenLimits(), to: limits) }, from: yaml)
        _ = try record("removing a repository", { try RepositoriesConfig.removing("api", from: $0) }, from: yaml)

        for key in SettingsUIManifest.keyPaths where !written.contains(where: { $0 == key || $0.hasPrefix(key + ".") }) {
            XCTFail("SettingsUIManifest.keyPaths lists `\(key)`, which no editor writes")
        }
    }

    func testReadsKeyPathsOfBlockMappingsListsAndFlowValues() {
        let yaml = """
            agent:  # comment
              run_profiles:
                qa: { model: x }
            repositories:
            - key: web
              route:
                labels:
                  - backend
            """
        XCTAssertEqual(keyLines(yaml).map(\.path), [
            "agent", "agent.run_profiles", "agent.run_profiles.qa",
            "repositories", "repositories[].key", "repositories[].route", "repositories[].route.labels",
            "repositories[].route.labels",
        ])
    }

    // MARK: Helpers

    /// Whether `path` is a listed key, a key under a listed free-form map (`agent.run_profiles.qa`), or a
    /// section holding a listed key (`agent.limits`).
    private func covers(_ path: String) -> Bool {
        SettingsUIManifest.keyPaths.contains { $0 == path || path.hasPrefix($0 + ".") || $0.hasPrefix(path + ".") }
    }

    /// The key paths of the lines `after` adds, removes or changes compared to `before`.
    private func writtenPaths(from before: String, to after: String) -> Set<String> {
        let old = keyLines(before).map { $0.path + "\t" + $0.line }
        let new = keyLines(after).map { $0.path + "\t" + $0.line }
        var paths = Set<String>()
        for (lines, others) in [(old, new), (new, old)] {
            var remaining = others
            for line in lines {
                if let index = remaining.firstIndex(of: line) {
                    remaining.remove(at: index)
                } else {
                    paths.insert(String(line.prefix { $0 != "\t" }))
                }
            }
        }
        return paths
    }

    /// Each key or list item line of block-style YAML with its dotted key path; a list item adds `[]` to its
    /// list's path, and a scalar item reads as its list's key.
    private func keyLines(_ yaml: String) -> [(path: String, line: String)] {
        var parents: [(indent: Int, path: String)] = []
        var result: [(path: String, line: String)] = []
        for raw in yaml.components(separatedBy: "\n") {
            var content = Substring(raw.trimmingCharacters(in: .whitespaces))
            guard !content.isEmpty, !content.hasPrefix("#") else { continue }
            var indent = raw.prefix { $0 == " " }.count
            if content.hasPrefix("- ") {
                parents.removeAll { $0.indent > indent || ($0.indent == indent && $0.path.hasSuffix("[]")) }
                let item = (parents.last?.path ?? "") + "[]"
                content = content.dropFirst(2).drop { $0 == " " }
                guard let colon = content.firstIndex(of: ":"), content[colon...].hasPrefix(": ") || content.hasSuffix(":") else {
                    result.append((parents.last?.path ?? "", raw))
                    continue
                }
                parents.append((indent, item))
                indent = raw.count - content.count
            }
            guard let colon = content.firstIndex(of: ":") else { continue }
            parents.removeAll { $0.indent >= indent }
            let name = String(content[..<colon])
            let path = parents.last.map { $0.path + "." + name } ?? name
            result.append((path, raw))
            parents.append((indent, path))
        }
        return result
    }
}
