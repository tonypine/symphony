import XCTest
@testable import SymphonyBarCore

final class ManagedClonesTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/clones")
    private let running = SymphonyStatus.running(StateSnapshot(), external: false)

    private func managed(_ key: String, _ github: String, clonePath: String? = nil, worktrees: [String] = []) -> RepoStatus {
        RepoStatus(
            key: key,
            source: .managed(github: github, clonePath: clonePath, cloned: true),
            worktrees: worktrees.map { RepoStatus.Worktree(issueIdentifier: $0) }
        )
    }

    private func removal(
        _ status: SymphonyStatus,
        _ poll: ReposPoll?,
        gitHub: String = "Acme/Web",
        exists: Set<String> = ["/clones/acme/web/.git"]
    ) -> ManagedClones.Removal {
        ManagedClones.removal(gitHub: gitHub, root: root, status: status, poll: poll) { exists.contains($0) }
    }

    // MARK: Root

    func testRootFromTheConfig() {
        let home = NSHomeDirectory()
        XCTAssertEqual(ManagedClones.root(in: "workspaces:\n  root: ~/w\n", configPath: "/etc/s/symphony.yml").path,
                       home + "/.local/share/symphony/repos")
        XCTAssertEqual(ManagedClones.root(in: "", configPath: "/etc/s/symphony.yml").path, home + "/.local/share/symphony/repos")
        XCTAssertEqual(
            ManagedClones.root(in: "workspaces:\n  clones_root: ~/clones  # mine\n", configPath: "/etc/s/symphony.yml").path,
            home + "/clones"
        )
        XCTAssertEqual(
            ManagedClones.root(in: "workspaces:\n  clones_root: \"/var/c/\"\n", configPath: "/etc/s/symphony.yml").path,
            "/var/c"
        )
        XCTAssertEqual(
            ManagedClones.root(in: "workspaces:\n  clones_root: 'clones/../c'\n", configPath: "/etc/s/symphony.yml").path,
            "/etc/s/c"
        )
        // A null, an empty value and an inline mapping fall back to the default.
        for yaml in ["workspaces:\n  clones_root: ~\n", "workspaces:\n  clones_root:\n", "workspaces: {clones_root: /x}\n"] {
            XCTAssertEqual(ManagedClones.root(in: yaml, configPath: "/etc/s/symphony.yml").path, home + "/.local/share/symphony/repos")
        }
    }

    func testClonePathIsLowerCaseOwnerAndRepoUnderTheRoot() {
        XCTAssertEqual(ManagedClones.clonePath(root: root, gitHub: "Acme/Web").path, "/clones/acme/web")
    }

    // MARK: Removal

    func testAllowedWhileSymphonyIsStoppedOrNoAgentUsesTheClone() {
        XCTAssertEqual(removal(.stopped, nil), .allowed(path: "/clones/acme/web"))
        XCTAssertEqual(removal(.stopped, nil).path, "/clones/acme/web")
        XCTAssertNil(removal(.starting, nil).path)
        let poll = ReposPoll.repos([managed("web", "acme/web"), managed("api", "acme/api", worktrees: ["TP-1"])], warning: nil)
        XCTAssertEqual(removal(running, poll), .allowed(path: "/clones/acme/web"))
        XCTAssertEqual(removal(.paused(StateSnapshot(), external: true), poll), .allowed(path: "/clones/acme/web"))
    }

    func testBlockedWhileAnAgentWorksInAWorktreeOfTheClone() {
        XCTAssertEqual(
            removal(running, .repos([managed("web", "acme/web", worktrees: ["TP-1"])], warning: nil)),
            .blocked("TP-1 runs in a worktree of this clone. Remove it once that run finishes.")
        )
        // A second repo with the same source shares the clone.
        XCTAssertEqual(
            removal(running, .repos([managed("web", "acme/web"), managed("web-2", "ACME/web", worktrees: ["TP-2", "TP-3"])], warning: nil)),
            .blocked("TP-2, TP-3 run in a worktree of this clone. Remove it once they finish.")
        )
    }

    func testBlockedWhileTheAgentsAreUnknown() {
        XCTAssertEqual(removal(.starting, nil), .blocked("Symphony is starting and may be cloning the repo. Try again once it runs."))
        XCTAssertEqual(
            removal(.error("boom"), nil),
            .blocked("Symphony isn't answering, so the app can't tell whether an agent uses the clone.")
        )
        XCTAssertEqual(removal(running, nil), .blocked("Checking whether an agent uses the clone…"))
        for poll in [ReposPoll.unreachable, .unsupported, .failed("HTTP 500")] {
            XCTAssertEqual(
                removal(running, poll),
                .blocked("Symphony didn't list its running agents, so the app can't tell whether one uses the clone.")
            )
        }
        XCTAssertEqual(
            removal(running, .repos([managed("web", "acme/web")], warning: "timed out")),
            .blocked("Symphony couldn't list its running agents, so the app can't tell whether one uses the clone.")
        )
    }

    func testUsesSymphonysClonePathOnlyInsideTheRoot() {
        XCTAssertEqual(
            removal(running, .repos([managed("web", "acme/web", clonePath: "/clones/x/web")], warning: nil), exists: ["/clones/x/web/.git"]),
            .allowed(path: "/clones/x/web")
        )
        XCTAssertEqual(
            removal(running, .repos([managed("web", "acme/web", clonePath: "/elsewhere/web")], warning: nil)),
            .blocked("/elsewhere/web isn't inside Symphony's clones folder /clones, so the app didn't delete it.")
        )
    }

    func testBlockedBeforeTheFirstClone() {
        XCTAssertEqual(
            removal(.stopped, nil, exists: ["/clones/acme/web"]),
            .blocked("No clone at /clones/acme/web yet: Symphony clones the repo when it starts or on its next dispatch.")
        )
    }

    // MARK: Deleting

    func testIsInsideTheRootOnly() throws {
        let directory = uniqueTemporaryDirectory("managed-clones").resolvingSymlinksInPath()
        let files = FileManager.default
        let clones = directory.appendingPathComponent("repos")
        try files.createDirectory(at: clones.appendingPathComponent("acme/web"), withIntermediateDirectories: true)
        try files.createDirectory(at: directory.appendingPathComponent("mine"), withIntermediateDirectories: true)
        try files.createSymbolicLink(at: clones.appendingPathComponent("escape"), withDestinationURL: directory.appendingPathComponent("mine"))
        addTeardownBlock { try? files.removeItem(at: directory) }

        XCTAssertTrue(ManagedClones.isInside(clones.path + "/acme/web", root: clones))
        XCTAssertFalse(ManagedClones.isInside(clones.path, root: clones))
        XCTAssertFalse(ManagedClones.isInside(clones.path + "/", root: clones))
        XCTAssertFalse(ManagedClones.isInside(clones.path + "/acme/..", root: clones))
        XCTAssertFalse(ManagedClones.isInside(clones.path + "/../mine", root: clones))
        XCTAssertFalse(ManagedClones.isInside(clones.path + "-other/web", root: clones))
        XCTAssertFalse(ManagedClones.isInside(clones.path + "/escape", root: clones))
        XCTAssertFalse(ManagedClones.isInside("acme/web", root: clones))
    }

    func testRemovesOnlyAFolderInsideTheRoot() throws {
        let directory = uniqueTemporaryDirectory("managed-clones").resolvingSymlinksInPath()
        let files = FileManager.default
        let clones = directory.appendingPathComponent("repos")
        let clone = clones.appendingPathComponent("acme/web")
        let mine = directory.appendingPathComponent("mine")
        try files.createDirectory(at: clone.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try files.createDirectory(at: clones.appendingPathComponent("acme/api/.git"), withIntermediateDirectories: true)
        try files.createDirectory(at: mine, withIntermediateDirectories: true)
        try files.createSymbolicLink(at: clones.appendingPathComponent("escape"), withDestinationURL: mine)
        addTeardownBlock { try? files.removeItem(at: directory) }

        for outside in [mine.path, clones.path, clones.path + "/escape", clones.path + "/../mine"] {
            XCTAssertThrowsError(try ManagedClones.remove(outside, root: clones)) { error in
                XCTAssertEqual(error as? ManagedCloneError, .outsideRoot(path: outside, root: clones.path))
            }
        }
        XCTAssertTrue(ManagedClones.isDirectory(mine.path))
        XCTAssertTrue(ManagedClones.isDirectory(clone.path))

        guard case let .allowed(path) = ManagedClones.removal(gitHub: "acme/web", root: clones, status: .stopped, poll: nil) else {
            return XCTFail("removal should be allowed")
        }
        try ManagedClones.remove(path, root: clones)

        XCTAssertFalse(files.fileExists(atPath: clone.path))
        XCTAssertTrue(ManagedClones.isDirectory(clones.appendingPathComponent("acme/api/.git").path))
        XCTAssertTrue(ManagedClones.isDirectory(mine.path))
    }

    func testQuestionAndMessage() {
        let question = ManagedClones.question(key: "web", gitHub: "acme/web", path: "/clones/acme/web")
        XCTAssertEqual(question.title, "Remove Symphony's clone of acme/web?")
        XCTAssertEqual(question.message, "This deletes /clones/acme/web. Your own checkouts aren't touched, and web stays "
            + "connected: Symphony clones it again when it starts or on its next dispatch.")
        XCTAssertEqual(ManagedClones.removedMessage(key: "web", path: "/clones/acme/web"), "Removed Symphony's clone of web at /clones/acme/web.")
    }

    func testReadsTheRootFromTheFile() throws {
        let directory = uniqueTemporaryDirectory("managed-clones")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("symphony.yml")
        try "workspaces:\n  clones_root: clones\n".write(to: url, atomically: false, encoding: .utf8)

        XCTAssertEqual(try SymphonyConfigFile(path: url.path).readClonesRoot(), directory.appendingPathComponent("clones").standardizedFileURL)
    }
}
