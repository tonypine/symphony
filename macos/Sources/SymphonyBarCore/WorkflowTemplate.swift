import Foundation

/// The files at a repo's top, enough to guess its stack: the names there, and a reader for a few files by their path
/// from the top.
public struct RepoFiles {
    public var names: Set<String>
    /// The text of a file, nil when it can't be read.
    public var read: (String) -> String?

    public init(names: Set<String>, read: @escaping (String) -> String? = { _ in nil }) {
        self.names = names
        self.read = read
    }

    /// The working tree of the checkout at `path`.
    public static func checkout(_ path: String) -> RepoFiles {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        return RepoFiles(names: Set(names)) { relative in
            try? String(contentsOfFile: (path as NSString).appendingPathComponent(relative), encoding: .utf8)
        }
    }
}

/// What the template could tell about a repo from its files.
public struct WorkflowStack: Equatable {
    /// The Android app the `android_app` QA playbook builds.
    public struct AndroidApp: Equatable {
        public var build: String
        public var apkPath: String
        /// Empty when the app's build file names none.
        public var applicationIds: [String]

        public init(build: String, apkPath: String, applicationIds: [String]) {
            self.build = build
            self.apkPath = apkPath
            self.applicationIds = applicationIds
        }
    }

    /// For example "Elixir", "Kotlin" or "TypeScript"; nil when nothing was recognised.
    public var language: String?
    /// For example "Mix", "Gradle" or "pnpm".
    public var buildTool: String?
    /// Installs dependencies in a new workspace, for the `after_create` hook.
    public var setup: String?
    public var test: String?
    /// Cheap checks to run before each push, such as a formatter or a linter.
    public var checks: [String]
    /// The file that pins dependency versions, for the dependency guardrail.
    public var lockfile: String?
    public var androidApp: AndroidApp?
    /// The script a web app's dev server starts with, for the commented `verification` block.
    public var devServer: String?

    public init(
        language: String? = nil,
        buildTool: String? = nil,
        setup: String? = nil,
        test: String? = nil,
        checks: [String] = [],
        lockfile: String? = nil,
        androidApp: AndroidApp? = nil,
        devServer: String? = nil
    ) {
        self.language = language
        self.buildTool = buildTool
        self.setup = setup
        self.test = test
        self.checks = checks
        self.lockfile = lockfile
        self.androidApp = androidApp
        self.devServer = devServer
    }

    /// "Elixir · Mix · tests: mix test", or what was found of it.
    public var summary: String {
        var parts = [language, buildTool].compactMap { $0 }
        if parts.isEmpty { parts.append("Stack not recognised") }
        parts.append(test.map { "tests: \($0)" } ?? "no test command found")
        if androidApp != nil { parts.append("Android QA") }
        return parts.joined(separator: " · ")
    }
}

/// The `WORKFLOW.md` the Add Repo sheet offers for a repo that has none, in the shape Symphony's own repos use:
/// the setup hook, QA playbooks and `playbook` settings in the front matter, then the repo's commands and steps
/// above the `{% render "playbook" %}` line, which Symphony expands to its standard playbook (`docs/playbook.md`).
/// It guesses only from the files at the repo's top.
public enum WorkflowTemplate {
    public static let fileName = "WORKFLOW.md"

    /// The stack `files` show. A repo-owned `make test` wins over a language's default test command.
    public static func detect(_ files: RepoFiles) -> WorkflowStack {
        var stack: WorkflowStack
        if files.names.contains("mix.exs") {
            stack = elixir(files)
        } else if !files.names.isDisjoint(with: ["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"]) {
            stack = gradle(files)
        } else if files.names.contains("package.json") {
            stack = node(files)
        } else if files.names.contains("Cargo.toml") {
            stack = WorkflowStack(
                language: "Rust", buildTool: "Cargo", setup: "cargo fetch", test: "cargo test",
                checks: ["cargo fmt --check", "cargo clippy -- -D warnings"], lockfile: lockfile("Cargo.lock", files)
            )
        } else if files.names.contains("go.mod") {
            stack = WorkflowStack(
                language: "Go", buildTool: "Go modules", setup: "go mod download", test: "go test ./...",
                checks: ["go vet ./..."], lockfile: lockfile("go.sum", files)
            )
        } else if files.names.contains("Package.swift") {
            stack = WorkflowStack(
                language: "Swift", buildTool: "SwiftPM", setup: "swift package resolve", test: "swift test",
                lockfile: lockfile("Package.resolved", files)
            )
        } else {
            stack = WorkflowStack()
        }
        if let makefile = files.names.contains("Makefile") ? files.read("Makefile") : nil,
           makefile.range(of: #"(?m)^test\s*:"#, options: .regularExpression) != nil {
            stack.test = "make test"
            if stack.buildTool == nil { stack.buildTool = "Make" }
        }
        return stack
    }

    /// The whole file for `stack`, with agents branching from and opening pull requests against `baseBranch`.
    public static func render(_ stack: WorkflowStack, gitHub: String, baseBranch: String) -> String {
        let base = baseBranch.trimmingWhitespace().isEmpty ? AddRepo.defaultBaseBranch : baseBranch.trimmingWhitespace()
        return frontMatter(stack) + "\n" + body(stack, gitHub: gitHub, base: base)
    }

    // MARK: Stacks

    private static func elixir(_ files: RepoFiles) -> WorkflowStack {
        let mix = files.read("mix.exs") ?? ""
        let usesMise = !files.names.isDisjoint(with: ["mise.toml", ".mise.toml", ".tool-versions"])
        var checks = ["mix format --check-formatted", "mix compile --warnings-as-errors"]
        if mix.contains(":credo") { checks.append("mix credo --strict <changed files>") }
        return WorkflowStack(
            language: "Elixir",
            buildTool: "Mix",
            setup: usesMise ? "mise trust && mise exec -- mix deps.get" : "mix deps.get",
            test: "mix test",
            checks: checks,
            lockfile: lockfile("mix.lock", files)
        )
    }

    private static func gradle(_ files: RepoFiles) -> WorkflowStack {
        let gradlew = files.names.contains("gradlew") ? "./gradlew" : "gradle"
        let buildFiles = ["build.gradle.kts", "build.gradle", "settings.gradle.kts", "settings.gradle"]
            .filter { files.names.contains($0) }
        let rootText = buildFiles.compactMap(files.read).joined(separator: "\n")
        let appBuild = files.names.contains("app") ? (files.read("app/build.gradle.kts") ?? files.read("app/build.gradle")) : nil
        let kotlin = buildFiles.contains { $0.hasSuffix(".kts") } || rootText.contains("kotlin")
            || (appBuild?.contains("kotlin") ?? false)
        var stack = WorkflowStack(
            language: kotlin ? "Kotlin" : "Java",
            buildTool: "Gradle",
            test: "\(gradlew) test",
            lockfile: files.names.contains("gradle") ? lockfile("gradle/libs.versions.toml", files, read: true) : nil
        )
        if let appBuild, appBuild.contains("com.android.application") {
            stack.buildTool = "Gradle (Android)"
            stack.test = "\(gradlew) testDebugUnitTest"
            stack.checks = ["\(gradlew) lintDebug"]
            stack.androidApp = WorkflowStack.AndroidApp(
                build: #"ANDROID_HOME="$HOME/Library/Android/sdk" "# + "\(gradlew) :app:assembleDebug",
                apkPath: "app/build/outputs/apk/debug/app-debug.apk",
                applicationIds: firstMatch(#"applicationId\s*=?\s*["']([^"']+)["']"#, in: appBuild).map { [$0] } ?? []
            )
        }
        return stack
    }

    private static func node(_ files: RepoFiles) -> WorkflowStack {
        let package = files.read("package.json").flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [String: Any] ?? [:]
        let scripts = package["scripts"] as? [String: String] ?? [:]
        let dependencies = ["dependencies", "devDependencies"].flatMap { (package[$0] as? [String: Any] ?? [:]).keys }

        let manager: (name: String, lockfile: String, install: String)
        if files.names.contains("pnpm-lock.yaml") {
            manager = ("pnpm", "pnpm-lock.yaml", "pnpm install --frozen-lockfile")
        } else if files.names.contains("yarn.lock") {
            manager = ("yarn", "yarn.lock", "yarn install --frozen-lockfile")
        } else if !files.names.isDisjoint(with: ["bun.lockb", "bun.lock"]) {
            manager = ("bun", files.names.contains("bun.lock") ? "bun.lock" : "bun.lockb", "bun install")
        } else if files.names.contains("package-lock.json") {
            manager = ("npm", "package-lock.json", "npm ci")
        } else {
            manager = ("npm", "", "npm install")
        }
        func run(_ script: String) -> String {
            switch (manager.name, script) {
            case ("npm", "test"): return "npm test"
            case ("npm", _), ("bun", _): return "\(manager.name) run \(script)"
            default: return "\(manager.name) \(script)"
            }
        }

        // `npm init` writes a test script that only fails.
        let test = scripts["test"].flatMap { $0.contains("no test specified") ? nil : run("test") }
        return WorkflowStack(
            language: files.names.contains("tsconfig.json") || dependencies.contains("typescript") ? "TypeScript" : "JavaScript",
            buildTool: manager.name,
            setup: manager.install,
            test: test,
            checks: ["lint", "typecheck"].filter { scripts[$0] != nil }.map(run),
            lockfile: manager.lockfile.isEmpty ? nil : manager.lockfile,
            devServer: scripts["dev"] != nil ? run("dev") : nil
        )
    }

    /// `name` when the repo has it at its top, or with `read` when a read finds it below.
    private static func lockfile(_ name: String, _ files: RepoFiles, read: Bool = false) -> String? {
        (read ? files.read(name) != nil : files.names.contains(name)) ? name : nil
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    // MARK: Front matter

    private static func frontMatter(_ stack: WorkflowStack) -> String {
        var lines = [
            "---",
            "# Drafted by Symphony's Add Repo sheet from the files at the repo's top. Check the commands, then run",
            "# `symphony workflow preview --file WORKFLOW.md` to see the prompt agents get.",
        ]
        if let setup = stack.setup {
            lines += ["hooks:", "  # Runs once in each new workspace, before the agent starts.", "  after_create: |", "    \(setup)"]
        } else {
            lines += [
                "# No setup command was found. To install dependencies in each new workspace, before the agent starts:",
                "#   after_create: |",
                "#     ./scripts/setup",
                "hooks: {}",
            ]
        }
        if let app = stack.androidApp {
            lines += [
                "# Auto Review's QA playbooks this repo turns on; symphony.yml's `auto_review.android.avd` names the emulator.",
                "auto_review:",
                "  playbooks:",
                "    android_app:",
                "      build: \(yamlQuoted(app.build))",
                "      apk_path: \(app.apkPath)",
            ]
            if app.applicationIds.isEmpty {
                lines.append("      application_ids: []  # the app's applicationId, such as com.example.app")
            } else {
                lines.append("      application_ids: [\(app.applicationIds.map(yamlQuoted).joined(separator: ", "))]")
            }
        }
        if let devServer = stack.devServer {
            lines += [
                "# To have Auto Review test the web app in a browser, serve it on Symphony's port:",
                "# verification:",
                "#   dev_server:",
                // npm passes arguments on to the script only after `--`.
                "#     start_cmd: \"\(devServer)\(devServer.hasPrefix("npm ") ? " --" : "") --port $SYMPHONY_VERIFICATION_PORT\"",
                "#     health_check_url: \"http://127.0.0.1:${SYMPHONY_VERIFICATION_PORT}/\"",
            ]
        }
        lines += [
            "# The body's last line expands to Symphony's playbook. It leaves out these two partials, which the",
            "# body's Step 1 relies on.",
            "playbook:",
        ]
        if let lockfile = stack.lockfile { lines.append("  lockfile: \(lockfile)") }
        lines += ["  partials:", "    workpad_bootstrap: 55", "    reproduce_and_blast_radius: 56", "---"]
        return lines.joined(separator: "\n") + "\n"
    }

    private static func yamlQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "''") + "'"
    }

    // MARK: Body

    private static func body(_ stack: WorkflowStack, gitHub: String, base: String) -> String {
        var commands: [String] = []
        if let setup = stack.setup { commands.append("- Set up: `\(setup)`. The `after_create` hook runs it in each new workspace.") }
        if let test = stack.test {
            commands.append("- Test: `\(test)`. Before each push, run the tests of the code you changed, not the whole suite.")
        } else {
            commands.append("- Test: no test command was found. Find the repo's own in its README or CI workflows.")
        }
        if !stack.checks.isEmpty {
            commands.append("- Checks before each push: \(stack.checks.map { "`\($0)`" }.joined(separator: ", ")).")
        }
        commands.append("- CI runs the full suite on every push and is the gate: leave the whole suite and slow checks to it.")
        let stackLine = [stack.language, stack.buildTool].compactMap { $0 }.joined(separator: ", built with ")

        return """
        You are working on a Linear ticket `{{ issue.identifier }}` in the `\(gitHub)` repository.

        ## Repository

        \(stackLine.isEmpty ? "" : "- Stack: \(stackLine).\n")- Base branch: `\(base)`. Branch from `origin/\(base)` and open pull requests against it.
        - Read the repo's own docs (`README.md`, `AGENTS.md`, `CLAUDE.md`, `CONTRIBUTING.md`) before changing code, and
          follow their conventions.

        ## Commands

        \(commands.joined(separator: "\n"))
        - For long-running commands, use long tool waits, and keep the output you read back small: the failing
          command, its exit code and the relevant error lines.

        ## Steps

        - Step 0, route: fetch the issue and route it per the Status map below. For `Todo`, move the issue to
          `In Progress` before any other tool call. If the branch's pull request is closed or merged, start a fresh
          branch from `origin/\(base)`. A ticket with the `plan` label follows `Parent tickets` instead of Steps 1 and 2.
        - Step 1, start: find or create the workpad, then capture a reproduction signal and the blast radius before
          the first edit (both below).
        - Step 2, execute: merge the latest `origin/\(base)` into the branch, implement the plan with the workpad
          checklist current, and run the checks and the tests of the changed code (see Commands) until they pass.
          Review `git diff origin/\(base)..HEAD` for debug output, stray files and temporary edits, then commit. Push
          and open a pull request against `\(base)` linked to the issue: that push hands the ticket to `Code Review`.
          Keep validation evidence in the workpad, not in the pull request body.
        - Step 3, review: in `Code Review`, `QA` and `Merging`, make no changes; Symphony brings review comments back
          as `In Progress` on the same pull request.
        - Step 4, rework: continue on the same pull request and branch, address what sent it back, and push.

        {% render "playbook" %}

        """
    }
}
