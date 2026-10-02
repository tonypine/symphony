import XCTest
@testable import SymphonyBarCore

final class ChildLaunchTests: XCTestCase {
    private let key = "lin_api_TOP_SECRET"
    private let files = StubFileChecker(files: ["/src/symphony/bin/symphony"])

    private func settings(prefix: String = "mise exec --", config: String = "/src/symphony/symphony.yml") -> AppSettings {
        AppSettings(checkoutPath: "/src/symphony", configPath: config, commandPrefix: prefix, developmentMode: true)
    }

    private func build(
        _ settings: AppSettings? = nil,
        key: String? = nil,
        extra: [EnvironmentVariable] = [],
        base: [String: String] = ["HOME": "/Users/me", "PATH": "/usr/bin:/bin", "USER": "me"]
    ) throws -> ChildLaunch {
        try ChildLaunchBuilder.build(
            settings: settings ?? self.settings(),
            secrets: SecretSettings(linearAPIKey: key ?? self.key, extraEnvironment: extra),
            baseEnvironment: base,
            files: files
        )
    }

    func testDefaultCommandRunsSymphonyThroughAZshLoginShellWithMise() throws {
        let launch = try build()

        XCTAssertEqual(launch.executable, "/bin/zsh")
        XCTAssertEqual(
            launch.arguments,
            ["-lc", "exec mise exec -- ./bin/symphony --config /src/symphony/symphony.yml"]
        )
        XCTAssertEqual(launch.workingDirectory, "/src/symphony")
    }

    func testDefaultSettingsUseTheMisePrefix() {
        XCTAssertEqual(AppSettings().commandPrefix, "mise exec --")
    }

    func testEmptyPrefixRunsSymphonyDirectly() throws {
        let launch = try build(settings(prefix: ""))

        XCTAssertEqual(launch.script, "exec ./bin/symphony --config /src/symphony/symphony.yml")
    }

    func testPrefixWordsAndConfigPathAreQuotedForTheShell() throws {
        let config = "/Users/me/My Configs/it's symphony.yml"
        let launch = try build(settings(prefix: "env 'A=b c' mise exec --", config: config))

        XCTAssertEqual(
            launch.script,
            "exec env 'A=b c' mise exec -- ./bin/symphony --config '/Users/me/My Configs/it'\\''s symphony.yml'"
        )
        XCTAssertEqual(
            ShellWords.split(launch.script),
            ["exec", "env", "A=b c", "mise", "exec", "--", "./bin/symphony", "--config", config]
        )
    }

    func testSettingsAreTrimmedBeforeBuilding() throws {
        let launch = try build(
            AppSettings(
                checkoutPath: " /src/symphony ",
                configPath: "\t/src/s.yml\n",
                commandPrefix: "  ",
                developmentMode: true
            )
        )

        XCTAssertEqual(launch.workingDirectory, "/src/symphony")
        XCTAssertEqual(launch.script, "exec ./bin/symphony --config /src/s.yml")
    }

    func testEnvironmentCarriesTheKeyAndExtraVariablesOnTopOfTheAppEnvironment() throws {
        let launch = try build(
            extra: [
                EnvironmentVariable(name: "GITHUB_TOKEN", value: "ghp secret"),
                EnvironmentVariable(name: "USER", value: "override"),
            ]
        )

        XCTAssertEqual(launch.environment["LINEAR_API_KEY"], key)
        XCTAssertEqual(launch.environment["GITHUB_TOKEN"], "ghp secret")
        XCTAssertEqual(launch.environment["USER"], "override")
        XCTAssertEqual(launch.environment["HOME"], "/Users/me")
    }

    func testSecretsNeverAppearInTheCommandLine() throws {
        let launch = try build(extra: [EnvironmentVariable(name: "GITHUB_TOKEN", value: "ghp_ALSO_SECRET")])
        let commandLine = ([launch.executable] + launch.arguments).joined(separator: " ")

        XCTAssertFalse(commandLine.contains(key))
        XCTAssertFalse(commandLine.contains("LINEAR_API_KEY"))
        XCTAssertFalse(commandLine.contains("ghp_ALSO_SECRET"))
        XCTAssertFalse(launch.workingDirectory.contains(key))
    }

    func testKeyIsTrimmedBeforeExport() throws {
        let launch = try build(key: "  \(key)\n")

        XCTAssertEqual(launch.environment["LINEAR_API_KEY"], key)
    }

    func testEmptyOrBlankKeyIsTreatedAsNotSet() {
        for blank in ["", "   ", "\n\t"] {
            XCTAssertThrowsError(try build(key: blank)) { error in
                XCTAssertEqual(error as? LaunchProblem, .linearAPIKeyMissing)
            }
        }
        XCTAssertEqual(LaunchProblem.linearAPIKeyMissing.message, "Linear API key not set. Add it in Settings.")
    }

    func testEnvironmentNeverExportsAnEmptyKey() {
        let environment = ChildLaunchBuilder.environment(
            base: ["PATH": "/usr/bin"],
            secrets: SecretSettings(linearAPIKey: "", extraEnvironment: [EnvironmentVariable(name: "", value: "x")])
        )

        XCTAssertNil(environment["LINEAR_API_KEY"])
        XCTAssertNil(environment[""])
    }

    func testMissingSettingsAndBinaryAreReported() {
        func problem(_ settings: AppSettings, files: FileChecker? = nil) -> LaunchProblem? {
            do {
                _ = try ChildLaunchBuilder.build(
                    settings: settings,
                    secrets: SecretSettings(linearAPIKey: key),
                    baseEnvironment: [:],
                    files: files ?? self.files
                )
                return nil
            } catch {
                return error as? LaunchProblem
            }
        }

        XCTAssertEqual(problem(AppSettings(configPath: "/s.yml", developmentMode: true)), .checkoutPathMissing)
        XCTAssertEqual(problem(AppSettings(checkoutPath: "/src/symphony", developmentMode: true)), .configPathMissing)
        XCTAssertEqual(problem(settings(prefix: "env 'A")), .commandPrefixInvalid)
        XCTAssertEqual(
            problem(settings(), files: StubFileChecker()),
            .symphonyBinaryMissing("/src/symphony/bin/symphony")
        )
        XCTAssertNil(problem(settings()))
    }

    // MARK: Embedded Symphony (Development mode off)

    private let embedded = "/Applications/Symphony.app/Contents/Resources/symphony"

    private func buildEmbedded(
        _ settings: AppSettings = AppSettings(configPath: "/Users/me/ops/symphony.yml"),
        key: String = "lin_api_TOP_SECRET",
        embeddedPath: String? = "/Applications/Symphony.app/Contents/Resources/symphony",
        files: FileChecker? = nil
    ) throws -> ChildLaunch {
        try ChildLaunchBuilder.build(
            settings: settings,
            secrets: SecretSettings(
                linearAPIKey: key,
                extraEnvironment: [EnvironmentVariable(name: "GITHUB_TOKEN", value: "ghp_ALSO_SECRET")]
            ),
            baseEnvironment: ["HOME": "/Users/me", "PATH": "/usr/bin:/bin"],
            embeddedSymphonyPath: embeddedPath,
            files: files ?? StubFileChecker(files: [embedded])
        )
    }

    func testEmbeddedModeRunsTheBundledBinaryDirectlyFromTheConfigFolder() throws {
        let launch = try buildEmbedded()

        XCTAssertEqual(launch.executable, embedded)
        XCTAssertEqual(launch.arguments, ["--config", "/Users/me/ops/symphony.yml"])
        XCTAssertEqual(launch.workingDirectory, "/Users/me/ops")
    }

    func testEmbeddedModeIgnoresTheCheckoutAndCommandPrefix() throws {
        let launch = try buildEmbedded(
            AppSettings(checkoutPath: "/src/symphony", configPath: " /Users/me/My Configs/s.yml ", commandPrefix: "env 'A")
        )

        XCTAssertEqual(launch.executable, embedded)
        XCTAssertEqual(launch.arguments, ["--config", "/Users/me/My Configs/s.yml"])
        XCTAssertEqual(launch.workingDirectory, "/Users/me/My Configs")
    }

    func testEmbeddedModeKeepsSecretsInTheEnvironmentOnly() throws {
        let launch = try buildEmbedded()
        let commandLine = ([launch.executable] + launch.arguments).joined(separator: " ")

        XCTAssertEqual(launch.environment["LINEAR_API_KEY"], key)
        XCTAssertEqual(launch.environment["GITHUB_TOKEN"], "ghp_ALSO_SECRET")
        XCTAssertEqual(launch.environment["PATH"], "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin:/Users/me/.local/bin")
        XCTAssertFalse(commandLine.contains(key))
        XCTAssertFalse(commandLine.contains("ghp_ALSO_SECRET"))
    }

    func testEmbeddedModeReportsMissingSettingsAndBinary() {
        func problem(_ build: () throws -> ChildLaunch) -> LaunchProblem? {
            do {
                _ = try build()
                return nil
            } catch {
                return error as? LaunchProblem
            }
        }

        XCTAssertEqual(problem { try buildEmbedded(AppSettings()) }, .configPathMissing)
        XCTAssertEqual(problem { try buildEmbedded(key: " ") }, .linearAPIKeyMissing)
        XCTAssertEqual(problem { try buildEmbedded(embeddedPath: nil) }, .embeddedSymphonyMissing)
        XCTAssertEqual(problem { try buildEmbedded(files: StubFileChecker()) }, .embeddedSymphonyMissing)
        XCTAssertNil(problem { try buildEmbedded() })
        XCTAssertEqual(
            LaunchProblem.embeddedSymphonyMissing.message,
            "This build has no embedded Symphony; turn on Development mode in Settings."
        )
        XCTAssertTrue(LaunchProblem.embeddedSymphonyMissing.isFixedInSettings)
    }

    func testEmbeddedSymphonyLivesInTheBundleResources() {
        XCTAssertEqual(EmbeddedSymphony.path(resourcesPath: "/Applications/Symphony.app/Contents/Resources"), embedded)
        XCTAssertNil(EmbeddedSymphony.path(resourcesPath: nil))
        XCTAssertNil(EmbeddedSymphony.path(resourcesPath: ""))
        XCTAssertTrue(EmbeddedSymphony.isAvailable(at: embedded, files: StubFileChecker(files: [embedded])))
        XCTAssertFalse(EmbeddedSymphony.isAvailable(at: embedded, files: StubFileChecker(directories: [embedded])))
        XCTAssertFalse(EmbeddedSymphony.isAvailable(at: nil, files: StubFileChecker(files: [embedded])))
    }

    func testOnlyTheBinaryProblemIsFixedOutsideSettings() {
        XCTAssertTrue(LaunchProblem.linearAPIKeyMissing.isFixedInSettings)
        XCTAssertTrue(LaunchProblem.checkoutPathMissing.isFixedInSettings)
        XCTAssertFalse(LaunchProblem.symphonyBinaryMissing("/x").isFixedInSettings)
        XCTAssertTrue(LaunchProblem.symphonyBinaryMissing("/src/bin/symphony").message.contains("mix build"))
    }

    func testPathKeepsTheAppPathAndAddsFallbacksOnce() throws {
        let launch = try build(base: ["HOME": "/Users/me", "PATH": "/usr/bin:/opt/homebrew/bin:/bin"])

        XCTAssertEqual(
            launch.environment["PATH"],
            "/usr/bin:/opt/homebrew/bin:/bin:/usr/local/bin:/Users/me/.local/bin"
        )
    }

    func testPathFallsBackToSystemDirectoriesWhenUnset() {
        XCTAssertEqual(
            ChildLaunchBuilder.pathWithFallbacks(nil, home: nil),
            "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
        )
    }
}
