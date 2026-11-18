import XCTest
@testable import SymphonyBarCore

/// The models the Runs page offers for each provider, and the providers each harness reaches.
final class RunModelListsTests: XCTestCase {
    func testEachHarnessReachesItsProviders() {
        XCTAssertEqual(RunProfilesConfig.providers(for: "claude").map(\.id), ["anthropic", "openrouter", "opencode-go"])
        XCTAssertEqual(RunProfilesConfig.providers(for: "codex").map(\.id), ["opencode-go", "openai"])
        XCTAssertEqual(RunProfilesConfig.providers(for: "opencode").map(\.id), ["opencode-go"])
    }

    func testAnthropicAndOpenAIModelsComeFromTheirLists() {
        let lists = RunModelLists()
        XCTAssertEqual(lists.models(for: RunProfilesConfig.anthropic), RunProfilesConfig.models)
        XCTAssertEqual(lists.models(for: RunProfilesConfig.openAI), RunProfilesConfig.openAIModels)
        // A value in the file that the list doesn't hold is still offered.
        XCTAssertEqual(
            lists.models(for: RunProfilesConfig.anthropic, including: "claude-old")?.last,
            RunProfileChoice(id: "claude-old", title: "claude-old")
        )
        XCTAssertEqual(lists.models(for: RunProfilesConfig.anthropic, including: "claude-opus-5-5"), RunProfilesConfig.models)
        XCTAssertEqual(lists.models(for: nil), [])
        XCTAssertEqual(lists.models(for: "acme", including: "x"), [RunProfileChoice(id: "x", title: "x")])
        XCTAssertNil(lists.failure(for: RunProfilesConfig.anthropic))
    }

    func testOpenRouterModelsAreTheOnesThatSupportTools() {
        var lists = RunModelLists()
        XCTAssertNil(lists.models(for: RunProfilesConfig.openRouter))
        XCTAssertNil(lists.failure(for: RunProfilesConfig.openRouter))

        lists.openRouter = .success([
            OpenRouterModel(id: "z/zeta", name: "Zeta", supportsTools: true),
            OpenRouterModel(id: "a/chat", name: "Acme Chat", supportsTools: true),
            OpenRouterModel(id: "a/text", name: "Acme Text", supportsTools: false),
        ])
        XCTAssertEqual(lists.models(for: RunProfilesConfig.openRouter), [
            RunProfileChoice(id: "a/chat", title: "Acme Chat"),
            RunProfileChoice(id: "z/zeta", title: "Zeta"),
        ])

        lists.openRouter = .failure(OpenRouterFailure("OpenRouter answered 503."))
        XCTAssertNil(lists.models(for: RunProfilesConfig.openRouter))
        XCTAssertEqual(lists.failure(for: RunProfilesConfig.openRouter), "OpenRouter answered 503.")
    }

    func testOpenCodeGoModelsComeFromOpencodeModels() {
        var lists = RunModelLists()
        XCTAssertNil(lists.models(for: RunProfilesConfig.openCodeGo))

        lists.openCodeGo = OpenCodeModels.result(status: 0, output: "opencode-go/kimi-k3\nopenrouter/acme/chat\n  opencode-go/glm-5  \nopencode-go/kimi-k3\nopencode-go/\n")
        XCTAssertEqual(lists.models(for: RunProfilesConfig.openCodeGo), [
            RunProfileChoice(id: "kimi-k3", title: "kimi-k3"),
            RunProfileChoice(id: "glm-5", title: "glm-5"),
        ])
        XCTAssertNil(lists.failure(for: RunProfilesConfig.openCodeGo))

        lists.openCodeGo = OpenCodeModels.result(status: 1, output: "loading\nError: no provider opencode-go\n\n")
        XCTAssertNil(lists.models(for: RunProfilesConfig.openCodeGo))
        XCTAssertEqual(lists.failure(for: RunProfilesConfig.openCodeGo), "Error: no provider opencode-go")
    }

    func testOpencodeModelsFailsWithoutModels() {
        XCTAssertEqual(OpenCodeModels.result(status: 0, output: "openrouter/x\n"), .failure(ModelListFailure("opencode models lists no OpenCode Go models.")))
        XCTAssertEqual(OpenCodeModels.result(status: 2, output: ""), .failure(ModelListFailure("opencode models exited with status 2.")))
    }

    func testRunsTheOpenCodeHarnessesProgram() {
        XCTAssertEqual(OpenCodeModels.script(command: nil), "opencode models opencode-go")
        XCTAssertEqual(OpenCodeModels.script(command: "/opt/tools/opencode --print-logs"), "/opt/tools/opencode models opencode-go")
        XCTAssertEqual(OpenCodeModels.script(command: "'/Applications/Open Code/opencode'"), "'/Applications/Open Code/opencode' models opencode-go")
        XCTAssertEqual(OpenCodeModels.script(command: "'unclosed"), "opencode models opencode-go")

        let launch = OpenCodeModels.launch(command: nil, environment: ["PATH": "/usr/bin"], workingDirectory: "/tmp")
        XCTAssertEqual(launch.executable, ChildLaunch.shell)
        XCTAssertEqual(launch.arguments, ["-lc", "opencode models opencode-go"])
        XCTAssertEqual(launch.environment, ["PATH": "/usr/bin"])
        XCTAssertEqual(launch.workingDirectory, "/tmp")
    }

    func testLoadsTheModelsAProgramPrints() async {
        let directory = NSTemporaryDirectory()
        let listing = ChildLaunch(
            executable: "/bin/sh", arguments: ["-c", "printf 'opencode-go/kimi-k3\\nopencode-go/glm-5\\n'"],
            workingDirectory: directory, environment: [:]
        )
        let loaded = await OpenCodeModels.load(listing)
        XCTAssertEqual(loaded, .success([RunProfileChoice(id: "kimi-k3", title: "kimi-k3"), RunProfileChoice(id: "glm-5", title: "glm-5")]))

        let slow = ChildLaunch(executable: "/bin/sh", arguments: ["-c", "exec sleep 5"], workingDirectory: directory, environment: [:])
        let timedOut = await OpenCodeModels.load(slow, timeout: 0.2)
        XCTAssertEqual(timedOut, .failure(ModelListFailure("opencode models took longer than 0 seconds.")))

        let missing = ChildLaunch(executable: "/nonexistent/opencode", arguments: [], workingDirectory: directory, environment: [:])
        guard case .failure(let failure) = await OpenCodeModels.load(missing) else { return XCTFail("ran a missing program") }
        XCTAssertTrue(failure.message.hasPrefix("Couldn't run opencode models"))
    }
}
