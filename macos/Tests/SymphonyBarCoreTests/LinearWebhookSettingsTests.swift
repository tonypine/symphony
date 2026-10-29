import XCTest
@testable import SymphonyBarCore

final class LinearWebhookSettingsTests: XCTestCase {
    private let config = """
        # Symphony operator config.
        linear:
          webhooks:
            enabled: false  # deliveries are counted only
            secret: $SYMPHONY_LINEAR_WEBHOOK_SECRET
        workspaces:
          root: ~/work
        """

    private let configSettings = LinearWebhookSettings(enabled: false, secret: .environment("SYMPHONY_LINEAR_WEBHOOK_SECRET"))

    // MARK: Reading

    func testReadsTheSettings() throws {
        XCTAssertEqual(try LinearWebhookSettings.values(in: config), configSettings)
        XCTAssertEqual(
            try LinearWebhookSettings.values(in: "linear:\n  webhooks:\n    enabled: TRUE\n    secret: \"$HOOK_1\"\n"),
            LinearWebhookSettings(enabled: true, secret: .environment("HOOK_1"))
        )
    }

    func testMissingAndNullKeysReadAsSymphonysDefaults() throws {
        XCTAssertEqual(LinearWebhookSettings(), LinearWebhookSettings(enabled: false, secret: .none))
        XCTAssertEqual(try LinearWebhookSettings.values(in: ""), LinearWebhookSettings())
        XCTAssertEqual(try LinearWebhookSettings.values(in: "linear:\n  api_key: $LINEAR_API_KEY\n"), LinearWebhookSettings())
        XCTAssertEqual(try LinearWebhookSettings.values(in: "linear:\n  webhooks:\n    enabled: ~\n    secret: null\n"), LinearWebhookSettings())
        XCTAssertEqual(try LinearWebhookSettings.values(in: "linear:\n  webhooks:\n    secret: \"\"\n"), LinearWebhookSettings())
        XCTAssertEqual(try LinearWebhookSettings.values(in: "linear:\n  webhooks:\n    enabled: False\n"), LinearWebhookSettings())
    }

    /// A literal is read whole, plain or quoted; a `$` followed by a name Symphony can't resolve is a literal too, as
    /// Symphony reads it.
    func testReadsALiteralSecret() throws {
        XCTAssertEqual(
            try LinearWebhookSettings.values(in: "linear:\n  webhooks:\n    secret: lin_wh_abc123  # rotated\n").secret,
            .literal("lin_wh_abc123")
        )
        XCTAssertEqual(try LinearWebhookSettings.values(in: "linear:\n  webhooks:\n    secret: \"a \\\"b\\\" c\"\n").secret, .literal("a \"b\" c"))
        XCTAssertEqual(try LinearWebhookSettings.values(in: "linear:\n  webhooks:\n    secret: 'it''s'\n").secret, .literal("it's"))
        XCTAssertEqual(try LinearWebhookSettings.values(in: "linear:\n  webhooks:\n    secret: $1abc\n").secret, .literal("$1abc"))
    }

    func testRefusesValuesItCannotReadWithoutNamingTheSecret() {
        XCTAssertThrowsError(try LinearWebhookSettings.values(in: "linear:\n  webhooks:\n    enabled: sometimes\n")) { error in
            XCTAssertEqual(error as? LinearWebhookSettingsError, .notOnOrOff(key: "linear.webhooks.enabled", value: "sometimes"))
        }
        XCTAssertThrowsError(try LinearWebhookSettings.values(in: "linear:\n  webhooks:\n    secret: \"hunter2\n")) { error in
            XCTAssertEqual(error as? LinearWebhookSettingsError, .unreadableSecret(key: "linear.webhooks.secret"))
            XCTAssertFalse(error.localizedDescription.contains("hunter2"))
        }
        XCTAssertThrowsError(try LinearWebhookSettings.values(in: "linear:\n  webhooks: {enabled: true}\n")) { error in
            XCTAssertEqual(error as? LinearWebhookSettingsError, .notABlock("webhooks"))
        }
        XCTAssertEqual(
            LinearWebhookSettingsError.notOnOrOff(key: "linear.webhooks.enabled", value: "sometimes").errorDescription,
            "`linear.webhooks.enabled: sometimes` in symphony.yml is not true or false. Change it by hand."
        )
        XCTAssertEqual(
            LinearWebhookSettingsError.unreadableSecret(key: "linear.webhooks.secret").errorDescription,
            "`linear.webhooks.secret` in symphony.yml is not a readable string. Change it by hand."
        )
        XCTAssertEqual(
            LinearWebhookSettingsError.notABlock("webhooks").errorDescription,
            "`webhooks:` in symphony.yml is not an indented block. Change the Linear webhook settings by hand."
        )
    }

    // MARK: Writing

    /// The operator turns the toggle on and saves: only the `enabled` line changes, its comment kept.
    func testTurningTheToggleOnRewritesOnlyItsLine() throws {
        var on = configSettings
        on.enabled = true
        XCTAssertEqual(
            changedLines(config, try LinearWebhookSettings.updating(config, from: configSettings, to: on)),
            ["    enabled: true  # deliveries are counted only"]
        )
        XCTAssertEqual(try LinearWebhookSettings.updating(config, from: configSettings, to: configSettings), config)
    }

    func testWritesTheSecretAsAReferenceALiteralOrNull() throws {
        func secretLine(_ secret: LinearWebhookSettings.Secret) throws -> [String] {
            var new = configSettings
            new.secret = secret
            return changedLines(config, try LinearWebhookSettings.updating(config, from: configSettings, to: new))
        }
        XCTAssertEqual(try secretLine(.environment("LINEAR_HOOK")), ["    secret: $LINEAR_HOOK"])
        XCTAssertEqual(try secretLine(.literal("lin_wh_a\"b")), ["    secret: \"lin_wh_a\\\"b\""])
        XCTAssertEqual(try secretLine(.literal("yes")), ["    secret: \"yes\""])
        XCTAssertEqual(try secretLine(.none), ["    secret: null"])

        // What is written reads back as the same secret.
        var literal = configSettings
        literal.secret = .literal("a: b \\ d")
        let written = try LinearWebhookSettings.updating(config, from: configSettings, to: literal)
        XCTAssertEqual(try LinearWebhookSettings.values(in: written), literal)
    }

    /// The operator turns the webhook on in a symphony.yml without the section: `linear.webhooks` is added with both
    /// lines, in the file's order, and nothing else changes.
    func testInsertsTheSectionWhenMissing() throws {
        let new = LinearWebhookSettings(enabled: true, secret: .environment("SYMPHONY_LINEAR_WEBHOOK_SECRET"))
        XCTAssertEqual(
            try LinearWebhookSettings.updating("workspaces:\n  root: ~/work\n", from: LinearWebhookSettings(), to: new),
            "workspaces:\n  root: ~/work\nlinear:\n  webhooks:\n    enabled: true\n    secret: $SYMPHONY_LINEAR_WEBHOOK_SECRET\n"
        )
        XCTAssertEqual(
            try LinearWebhookSettings.updating("linear:\n  api_key: $LINEAR_API_KEY\n", from: LinearWebhookSettings(), to: new),
            "linear:\n  webhooks:\n    enabled: true\n    secret: $SYMPHONY_LINEAR_WEBHOOK_SECRET\n  api_key: $LINEAR_API_KEY\n"
        )
    }

    func testRefusesToWriteIntoAnInlineSection() {
        XCTAssertThrowsError(
            try LinearWebhookSettings.updating("linear: {}\n", from: LinearWebhookSettings(), to: LinearWebhookSettings(enabled: true))
        ) { error in
            XCTAssertEqual(error as? LinearWebhookSettingsError, .notABlock("linear"))
        }
    }

    // MARK: Settings' fields

    func testFieldsShowTheSecretsSource() {
        XCTAssertTrue(LinearWebhookSettings.fields(.none) == (.environment, "", ""))
        XCTAssertTrue(LinearWebhookSettings.fields(.environment("HOOK")) == (.environment, "HOOK", ""))
        XCTAssertTrue(LinearWebhookSettings.fields(.literal("lin_wh_x")) == (.literal, "", "lin_wh_x"))
    }

    func testFieldsNameTheSecret() {
        XCTAssertEqual(LinearWebhookSettings.secret(source: .environment, name: " $HOOK_2 ", literal: "ignored"), .environment("HOOK_2"))
        XCTAssertEqual(LinearWebhookSettings.secret(source: .environment, name: "_hook", literal: ""), .environment("_hook"))
        XCTAssertEqual(LinearWebhookSettings.secret(source: .environment, name: "", literal: "x"), LinearWebhookSettings.Secret.none)
        XCTAssertEqual(LinearWebhookSettings.secret(source: .environment, name: "$", literal: ""), LinearWebhookSettings.Secret.none)
        XCTAssertNil(LinearWebhookSettings.secret(source: .environment, name: "MY-HOOK", literal: ""))
        XCTAssertNil(LinearWebhookSettings.secret(source: .environment, name: "1HOOK", literal: ""))
        XCTAssertNil(LinearWebhookSettings.secret(source: .environment, name: "HÖÖK", literal: ""))
        XCTAssertEqual(LinearWebhookSettings.secret(source: .literal, name: "HOOK", literal: " s3cret "), .literal(" s3cret "))
        XCTAssertEqual(LinearWebhookSettings.secret(source: .literal, name: "HOOK", literal: ""), LinearWebhookSettings.Secret.none)
    }

    // MARK: The file

    /// The operator turns the toggle on and saves: symphony.yml gains `enabled: true` and nothing else changes.
    func testFileWriteRunsTheCheckOnTheNewTextFirst() async throws {
        let url = try writeConfig()
        let file = SymphonyConfigFile(path: url.path)
        let loaded = try file.readLinearWebhookSettings()
        var new = loaded
        new.enabled = true
        var checked: String?
        let result = try await file.writeLinearWebhookSettings(new, from: loaded) { path in
            checked = try? String(contentsOfFile: path, encoding: .utf8)
            return .passed
        }
        XCTAssertEqual(result, .passed)
        let written = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(checked, written)
        XCTAssertEqual(changedLines(config, written), ["    enabled: true  # deliveries are counted only"])
        XCTAssertEqual(try file.readLinearWebhookSettings(), new)
    }

    func testFileWriteLeavesTheFileWhenTheCheckFails() async throws {
        let url = try writeConfig()
        let new = LinearWebhookSettings(enabled: true, secret: .none)
        let result = try await SymphonyConfigFile(path: url.path).writeLinearWebhookSettings(new, from: configSettings) { _ in
            .failed("linear.webhooks.secret is required when linear.webhooks.enabled is true")
        }
        XCTAssertEqual(result, .failed("linear.webhooks.secret is required when linear.webhooks.enabled is true"))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), config)
    }

    // MARK: Helpers

    private func writeConfig() throws -> URL {
        let directory = uniqueTemporaryDirectory("linear-webhook-settings")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("symphony.yml")
        try config.write(to: url, atomically: false, encoding: .utf8)
        return url
    }

    /// The lines of `after` that differ from `before`, which must have the same number of lines.
    private func changedLines(_ before: String, _ after: String) -> [String] {
        let old = before.components(separatedBy: "\n")
        let new = after.components(separatedBy: "\n")
        XCTAssertEqual(old.count, new.count)
        return zip(old, new).filter { $0 != $1 }.map(\.1)
    }
}
