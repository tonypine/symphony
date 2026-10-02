import XCTest
@testable import SymphonyBarCore

final class ChildLaunchTests: XCTestCase {
    private let key = "lin_api_TOP_SECRET"
    private let files = StubFileChecker(files: ["/src/symphony/bin/symphony"])

    private func settings(prefix: String = "mise exec --", config: String = "/src/symphony/symphony.yml") -> AppSettings {
        AppSettings(checkoutPath: "/src/symphony", configPath: config, commandPrefix: prefix)
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
            AppSettings(checkoutPath: " /src/symphony ", configPath: "\t/src/s.yml\n", commandPrefix: "  ")
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

        XCTAssertEqual(problem(AppSettings(configPath: "/s.yml")), .checkoutPathMissing)
        XCTAssertEqual(problem(AppSettings(checkoutPath: "/src/symphony")), .configPathMissing)
        XCTAssertEqual(problem(settings(prefix: "env 'A")), .commandPrefixInvalid)
        XCTAssertEqual(
            problem(settings(), files: StubFileChecker()),
            .symphonyBinaryMissing("/src/symphony/bin/symphony")
        )
        XCTAssertNil(problem(settings()))
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
