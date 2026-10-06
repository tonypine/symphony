import XCTest
@testable import SymphonyBarCore

final class WorkflowTemplateTests: XCTestCase {
    /// The drafts in `Fixtures/WorkflowTemplates`, which Symphony's own tests load and render too
    /// (`test/symphony_elixir/workflow_template_fixtures_test.exs`). Set `UPDATE_WORKFLOW_FIXTURES=1` to rewrite them.
    private func assertMatchesFixture(_ text: String, _ name: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let url = Self.fixtures.appendingPathComponent("\(name).md")
        if ProcessInfo.processInfo.environment["UPDATE_WORKFLOW_FIXTURES"] == "1" {
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        XCTAssertEqual(text, try String(contentsOf: url, encoding: .utf8), name, file: file, line: line)
    }

    private static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/WorkflowTemplates")

    private func files(_ contents: [String: String], names: Set<String> = []) -> RepoFiles {
        RepoFiles(names: names.union(contents.keys.filter { !$0.contains("/") })) { contents[$0] }
    }

    // MARK: Elixir

    func testDraftsAnElixirRepo() throws {
        let repo = files(
            ["mix.exs": "defp deps, do: [{:credo, \"~> 1.7\", only: :dev}]", "mix.lock": "%{}"],
            names: ["mise.toml", "lib", "test"]
        )

        let stack = WorkflowTemplate.detect(repo)

        XCTAssertEqual(stack, WorkflowStack(
            language: "Elixir",
            buildTool: "Mix",
            setup: "mise trust && mise exec -- mix deps.get",
            test: "mix test",
            checks: ["mix format --check-formatted", "mix compile --warnings-as-errors", "mix credo --strict <changed files>"],
            lockfile: "mix.lock"
        ))
        XCTAssertEqual(stack.summary, "Elixir · Mix · tests: mix test")
        try assertMatchesFixture(WorkflowTemplate.render(stack, gitHub: "acme/billing", baseBranch: "main"), "elixir")
    }

    func testAnElixirRepoWithoutMiseOrCredo() {
        let stack = WorkflowTemplate.detect(files(["mix.exs": "defp deps, do: []"]))
        XCTAssertEqual(stack.setup, "mix deps.get")
        XCTAssertEqual(stack.checks, ["mix format --check-formatted", "mix compile --warnings-as-errors"])
        XCTAssertNil(stack.lockfile)
    }

    // MARK: Gradle

    func testDraftsAnAndroidAppWithItsQAPlaybook() throws {
        let appBuild = """
            plugins {
                id("com.android.application")
                id("org.jetbrains.kotlin.android")
            }
            android {
                defaultConfig {
                    applicationId = "com.acme.notes"
                }
            }
            """
        let repo = files(
            ["settings.gradle.kts": "include(\":app\")", "build.gradle.kts": "", "app/build.gradle.kts": appBuild,
             "gradle/libs.versions.toml": "[versions]"],
            names: ["gradlew", "gradle", "app"]
        )

        let stack = WorkflowTemplate.detect(repo)

        XCTAssertEqual(stack, WorkflowStack(
            language: "Kotlin",
            buildTool: "Gradle (Android)",
            test: "./gradlew testDebugUnitTest",
            checks: ["./gradlew lintDebug"],
            lockfile: "gradle/libs.versions.toml",
            androidApp: WorkflowStack.AndroidApp(
                build: #"ANDROID_HOME="$HOME/Library/Android/sdk" ./gradlew :app:assembleDebug"#,
                apkPath: "app/build/outputs/apk/debug/app-debug.apk",
                applicationIds: ["com.acme.notes"]
            )
        ))
        XCTAssertEqual(stack.summary, "Kotlin · Gradle (Android) · tests: ./gradlew testDebugUnitTest · Android QA")
        try assertMatchesFixture(WorkflowTemplate.render(stack, gitHub: "acme/notes-android", baseBranch: "develop"), "android")
    }

    func testAnAndroidAppWithoutAnApplicationIdLeavesItToFillIn() {
        let repo = files(["build.gradle": "", "app/build.gradle": "apply plugin: 'com.android.application'"], names: ["app"])

        let stack = WorkflowTemplate.detect(repo)

        XCTAssertEqual(stack.language, "Java")
        XCTAssertEqual(stack.androidApp?.applicationIds, [])
        XCTAssertEqual(stack.androidApp?.build, #"ANDROID_HOME="$HOME/Library/Android/sdk" gradle :app:assembleDebug"#)
        XCTAssertTrue(WorkflowTemplate.render(stack, gitHub: "acme/app", baseBranch: "main")
            .contains("      application_ids: []  # the app's applicationId, such as com.example.app\n"))
    }

    func testAGradleLibraryIsNoAndroidApp() {
        let groovy = WorkflowTemplate.detect(files(["build.gradle": "plugins { id 'java' }"], names: ["gradlew", "gradle", "app"]))
        XCTAssertEqual(groovy, WorkflowStack(language: "Java", buildTool: "Gradle", test: "./gradlew test"))

        let kotlin = WorkflowTemplate.detect(files(["settings.gradle": "", "app/build.gradle": "apply plugin: 'kotlin'"], names: ["app"]))
        XCTAssertEqual(kotlin.language, "Kotlin")
        XCTAssertNil(kotlin.androidApp)
    }

    // MARK: Node

    func testDraftsANodeRepo() throws {
        let package = """
            {
              "name": "web",
              "scripts": {"dev": "vite", "test": "vitest run", "lint": "eslint .", "typecheck": "tsc --noEmit"},
              "devDependencies": {"vite": "^5.0.0"}
            }
            """
        let repo = files(["package.json": package], names: ["pnpm-lock.yaml", "tsconfig.json", "src"])

        let stack = WorkflowTemplate.detect(repo)

        XCTAssertEqual(stack, WorkflowStack(
            language: "TypeScript",
            buildTool: "pnpm",
            setup: "pnpm install --frozen-lockfile",
            test: "pnpm test",
            checks: ["pnpm lint", "pnpm typecheck"],
            lockfile: "pnpm-lock.yaml",
            devServer: "pnpm dev"
        ))
        try assertMatchesFixture(WorkflowTemplate.render(stack, gitHub: "acme/web", baseBranch: "main"), "node")
    }

    func testPicksTheNodePackageManagerFromItsLockFile() {
        func stack(_ lock: String?, scripts: String = #"{"test": "jest", "lint": "eslint ."}"#) -> WorkflowStack {
            WorkflowTemplate.detect(files(
                ["package.json": #"{"scripts": \#(scripts), "dependencies": {"typescript": "5"}}"#],
                names: lock.map { [$0] } ?? []
            ))
        }

        XCTAssertEqual(stack("yarn.lock").setup, "yarn install --frozen-lockfile")
        XCTAssertEqual(stack("yarn.lock").test, "yarn test")
        XCTAssertEqual(stack("bun.lockb").lockfile, "bun.lockb")
        XCTAssertEqual(stack("bun.lock").lockfile, "bun.lock")
        XCTAssertEqual(stack("bun.lock").checks, ["bun run lint"])
        XCTAssertEqual(stack("package-lock.json").setup, "npm ci")
        XCTAssertEqual(stack("package-lock.json").test, "npm test")
        XCTAssertEqual(stack("package-lock.json").checks, ["npm run lint"])
        XCTAssertEqual(stack(nil).setup, "npm install")
        XCTAssertNil(stack(nil).lockfile)
        XCTAssertEqual(stack(nil).language, "TypeScript")
        // `npm init` writes a test script that only fails.
        XCTAssertNil(stack(nil, scripts: #"{"test": "echo \"Error: no test specified\" && exit 1"}"#).test)

        let unreadable = WorkflowTemplate.detect(files(["package.json": "not json"]))
        XCTAssertEqual(unreadable.language, "JavaScript")
        XCTAssertNil(unreadable.test)
        XCTAssertEqual(unreadable.summary, "JavaScript · npm · no test command found")
    }

    // MARK: Other stacks

    func testDraftsOtherStacks() {
        XCTAssertEqual(WorkflowTemplate.detect(files([:], names: ["Cargo.toml", "Cargo.lock"])), WorkflowStack(
            language: "Rust", buildTool: "Cargo", setup: "cargo fetch", test: "cargo test",
            checks: ["cargo fmt --check", "cargo clippy -- -D warnings"], lockfile: "Cargo.lock"
        ))
        XCTAssertEqual(WorkflowTemplate.detect(files([:], names: ["go.mod"])), WorkflowStack(
            language: "Go", buildTool: "Go modules", setup: "go mod download", test: "go test ./...", checks: ["go vet ./..."]
        ))
        XCTAssertEqual(WorkflowTemplate.detect(files([:], names: ["Package.swift", "Package.resolved"])), WorkflowStack(
            language: "Swift", buildTool: "SwiftPM", setup: "swift package resolve", test: "swift test", lockfile: "Package.resolved"
        ))
    }

    func testPrefersTheRepoOwnMakeTest() {
        let makefile = "all: build\n\ntest: deps\n\tgo test ./...\n"
        XCTAssertEqual(WorkflowTemplate.detect(files(["Makefile": makefile], names: ["go.mod"])).test, "make test")

        let makeOnly = WorkflowTemplate.detect(files(["Makefile": makefile]))
        XCTAssertEqual(makeOnly, WorkflowStack(buildTool: "Make", test: "make test"))
        XCTAssertEqual(makeOnly.summary, "Make · tests: make test")

        XCTAssertEqual(WorkflowTemplate.detect(files(["Makefile": "build:\n\tcc main.c\n"], names: ["go.mod"])).test, "go test ./...")
    }

    func testDraftsAnUnknownRepoWithPlaceholders() throws {
        let stack = WorkflowTemplate.detect(files([:], names: ["README.md"]))

        XCTAssertEqual(stack, WorkflowStack())
        XCTAssertEqual(stack.summary, "Stack not recognised · no test command found")
        try assertMatchesFixture(WorkflowTemplate.render(stack, gitHub: "acme/notes", baseBranch: " "), "unknown")
    }

    // MARK: Files

    func testReadsACheckoutsFiles() throws {
        let folder = uniqueTemporaryDirectory("workflow-template")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("app"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        try "plugins {}".write(to: folder.appendingPathComponent("app/build.gradle.kts"), atomically: false, encoding: .utf8)
        try "".write(to: folder.appendingPathComponent("build.gradle.kts"), atomically: false, encoding: .utf8)

        let files = RepoFiles.checkout(folder.path)

        XCTAssertEqual(files.names, ["app", "build.gradle.kts"])
        XCTAssertEqual(files.read("app/build.gradle.kts"), "plugins {}")
        XCTAssertNil(files.read("missing"))
        XCTAssertEqual(RepoFiles.checkout(folder.appendingPathComponent("missing").path).names, [])
        XCTAssertNil(RepoFiles(names: []).read("anything"))
    }

    /// Each partial a draft renders is one Symphony ships, so the draft's prompt builds.
    func testRendersOnlyPartialsSymphonyShips() throws {
        let playbook = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../../../priv/playbook")
            .standardized
        let regex = try NSRegularExpression(pattern: #"\{% render "([a-z_]+)""#)
        for name in ["elixir", "android", "node", "unknown"] {
            let text = try String(contentsOf: Self.fixtures.appendingPathComponent("\(name).md"), encoding: .utf8)
            let partials = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
                .map { String(text[Range($0.range(at: 1), in: text)!]) }
            XCTAssertGreaterThan(partials.count, 10, name)
            for partial in partials {
                let file = playbook.appendingPathComponent("\(partial).liquid").path
                XCTAssertTrue(FileManager.default.fileExists(atPath: file), "\(name) renders \(partial), but \(file) is missing")
            }
        }
    }
}
