import XCTest
@testable import SymphonyBarCore

final class SettingsValidatorTests: XCTestCase {
    private let files = StubFileChecker(directories: ["/src/symphony"], files: ["/src/symphony/symphony.yml"])

    private let valid = AppSettings(
        checkoutPath: "/src/symphony",
        configPath: "/src/symphony/symphony.yml",
        commandPrefix: "mise exec --",
        stopTimeoutSeconds: 30,
        developmentMode: true
    )

    private let key = SecretSettings(linearAPIKey: "lin_api_secret")

    private func issues(_ settings: AppSettings, _ secrets: SecretSettings? = nil) -> [SettingsIssue] {
        SettingsValidator(files: files).validate(settings, secrets ?? key)
    }

    func testValidSettingsHaveNoIssues() {
        XCTAssertEqual(issues(valid), [])
    }

    func testEmptySettingsReportEveryRequiredField() {
        XCTAssertEqual(
            issues(AppSettings(developmentMode: true), SecretSettings()),
            [.checkoutPathMissing, .configPathMissing, .linearAPIKeyMissing]
        )
    }

    // MARK: Embedded Symphony (Development mode off)

    private let embedded = "/Applications/Symphony.app/Contents/Resources/symphony"

    private func embeddedIssues(_ settings: AppSettings, _ secrets: SecretSettings? = nil, hasBinary: Bool = true)
        -> [SettingsIssue]
    {
        var files = self.files
        if hasBinary { files.files.insert(embedded) }
        return SettingsValidator(files: files, embeddedSymphonyPath: embedded).validate(settings, secrets ?? key)
    }

    func testEmbeddedModeNeedsOnlySymphonyYmlAndTheKey() {
        XCTAssertEqual(embeddedIssues(AppSettings(configPath: "/src/symphony/symphony.yml")), [])
        XCTAssertEqual(embeddedIssues(AppSettings(), SecretSettings()), [.configPathMissing, .linearAPIKeyMissing])
    }

    func testEmbeddedModeSkipsTheCheckoutAndCommandPrefix() {
        let settings = AppSettings(
            checkoutPath: "relative/missing",
            configPath: "/src/symphony/symphony.yml",
            commandPrefix: "env 'A"
        )
        XCTAssertEqual(embeddedIssues(settings), [])
    }

    func testEmbeddedModeStillChecksTheConfigPathAndTimeout() {
        var settings = AppSettings(configPath: "/src/symphony/missing.yml")
        settings.stopTimeoutSeconds = 0
        XCTAssertEqual(embeddedIssues(settings), [.configPathNotFile, .stopTimeoutOutOfRange])
    }

    func testEmbeddedModeWithoutTheBinaryAsksForDevelopmentMode() {
        let settings = AppSettings(configPath: "/src/symphony/symphony.yml")
        XCTAssertEqual(embeddedIssues(settings, hasBinary: false), [.embeddedSymphonyMissing])
        XCTAssertEqual(SettingsValidator(files: files).validate(settings, key), [.embeddedSymphonyMissing])
        XCTAssertEqual(
            SettingsIssue.embeddedSymphonyMissing.message,
            "This build has no embedded Symphony; turn on Development mode in Settings."
        )
    }

    func testDevelopmentModeDoesNotNeedTheEmbeddedBinary() {
        XCTAssertEqual(SettingsValidator(files: files).validate(valid, key), [])
    }

    func testFirstRunNeedsSymphonyYmlAndInDevelopmentModeTheCheckout() {
        XCTAssertTrue(AppSettings().needsSetup)
        XCTAssertFalse(AppSettings(configPath: "/s.yml").needsSetup)
        XCTAssertTrue(AppSettings(configPath: " ", developmentMode: false).needsSetup)
        XCTAssertTrue(AppSettings(configPath: "/s.yml", developmentMode: true).needsSetup)
        XCTAssertFalse(AppSettings(checkoutPath: "/src", configPath: "/s.yml", developmentMode: true).needsSetup)
    }

    func testCheckoutPathMustBeAnAbsoluteExistingDirectory() {
        var settings = valid
        settings.checkoutPath = "src/symphony"
        XCTAssertEqual(issues(settings), [.checkoutPathNotAbsolute])

        settings.checkoutPath = "/src/missing"
        XCTAssertEqual(issues(settings), [.checkoutPathNotDirectory])

        settings.checkoutPath = "/src/symphony/symphony.yml"
        XCTAssertEqual(issues(settings), [.checkoutPathNotDirectory])
    }

    func testConfigPathMustBeAnAbsoluteExistingFile() {
        var settings = valid
        settings.configPath = "~/symphony.yml"
        XCTAssertEqual(issues(settings), [.configPathNotAbsolute])

        settings.configPath = "/src/symphony/missing.yml"
        XCTAssertEqual(issues(settings), [.configPathNotFile])

        settings.configPath = "/src/symphony"
        XCTAssertEqual(issues(settings), [.configPathNotFile])
    }

    func testCommandPrefixIsOptionalButMustBeBalanced() {
        var settings = valid
        settings.commandPrefix = ""
        XCTAssertEqual(issues(settings), [])

        settings.commandPrefix = "env 'A=b c"
        XCTAssertEqual(issues(settings), [.commandPrefixUnbalancedQuotes])
    }

    func testStopTimeoutMustBeInRange() {
        var settings = valid
        for seconds in [AppSettings.stopTimeoutRange.lowerBound, AppSettings.stopTimeoutRange.upperBound] {
            settings.stopTimeoutSeconds = seconds
            XCTAssertEqual(issues(settings), [], "\(seconds)")
        }
        for seconds in [0, -5, AppSettings.stopTimeoutRange.upperBound + 1] {
            settings.stopTimeoutSeconds = seconds
            XCTAssertEqual(issues(settings), [.stopTimeoutOutOfRange], "\(seconds)")
        }
    }

    func testExtraEnvironmentNamesAreChecked() {
        let secrets = SecretSettings(
            linearAPIKey: "lin_api_secret",
            extraEnvironment: [
                EnvironmentVariable(name: "GITHUB_TOKEN", value: "a"),
                EnvironmentVariable(name: "_private1", value: ""),
                EnvironmentVariable(name: "1BAD", value: "b"),
                EnvironmentVariable(name: "HAS-DASH", value: "c"),
                EnvironmentVariable(name: "", value: "d"),
                EnvironmentVariable(name: "GITHUB_TOKEN", value: "e"),
                EnvironmentVariable(name: "GITHUB_TOKEN", value: "f"),
                EnvironmentVariable(name: "LINEAR_API_KEY", value: "g"),
            ]
        )

        XCTAssertEqual(
            issues(valid, secrets),
            [
                .environmentNameInvalid("1BAD"),
                .environmentNameInvalid("HAS-DASH"),
                .environmentNameInvalid(""),
                .environmentNameDuplicate("GITHUB_TOKEN"),
                .environmentNameReserved("LINEAR_API_KEY"),
            ]
        )
    }

    func testEveryIssueHasAMessage() {
        let all: [SettingsIssue] = [
            .checkoutPathMissing, .checkoutPathNotAbsolute, .checkoutPathNotDirectory,
            .configPathMissing, .configPathNotAbsolute, .configPathNotFile,
            .commandPrefixUnbalancedQuotes, .stopTimeoutOutOfRange, .linearAPIKeyMissing, .embeddedSymphonyMissing,
            .environmentNameInvalid("1X"), .environmentNameDuplicate("X"), .environmentNameReserved("LINEAR_API_KEY"),
        ]
        for issue in all {
            XCTAssertFalse(issue.message.isEmpty, "\(issue)")
        }
        XCTAssertTrue(SettingsIssue.environmentNameInvalid("1X").message.contains("1X"))
    }

    func testTrimmingRemovesWhitespaceAndBlankRows() {
        let settings = AppSettings(
            checkoutPath: "  /src \n",
            configPath: "\t/src/s.yml ",
            commandPrefix: " mise exec -- ",
            developmentMode: true
        )
        XCTAssertEqual(
            settings.trimmed(),
            AppSettings(checkoutPath: "/src", configPath: "/src/s.yml", commandPrefix: "mise exec --", developmentMode: true)
        )

        let secrets = SecretSettings(
            linearAPIKey: " lin_api_secret\n",
            extraEnvironment: [
                EnvironmentVariable(name: "  ", value: ""),
                EnvironmentVariable(name: " TOKEN ", value: " keep spaces "),
            ]
        )
        XCTAssertEqual(
            secrets.trimmed(),
            SecretSettings(
                linearAPIKey: "lin_api_secret",
                extraEnvironment: [EnvironmentVariable(name: "TOKEN", value: " keep spaces ")]
            )
        )
    }

    func testLocalFileCheckerTellsFilesFromDirectories() {
        let file = URL(fileURLWithPath: #filePath)
        let directory = file.deletingLastPathComponent()

        let checker = LocalFileChecker()
        XCTAssertTrue(checker.isDirectory(atPath: directory.path))
        XCTAssertFalse(checker.isFile(atPath: directory.path))
        XCTAssertTrue(checker.isFile(atPath: file.path))
        XCTAssertFalse(checker.isDirectory(atPath: file.path))
        XCTAssertFalse(checker.isFile(atPath: directory.appendingPathComponent("missing.yml").path))
    }
}
