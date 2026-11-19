import XCTest
@testable import SymphonyBarCore

/// Test connection on a provider's page (TP-1540): OpenRouter's reads its key and models API, OpenCode Go's its models
/// list with the key; a pass and every way of failing, with no real key.
final class ProviderKeyCheckTests: XCTestCase {
    private let openRouterKeyURL = URL(string: "https://openrouter.ai/api/v1/key")!
    private let openRouterModelsURL = URL(string: "https://openrouter.ai/api/v1/models")!
    private let openCodeGoModelsURL = URL(string: "https://opencode.ai/inference/go/openai/v1/models")!

    private let keyBody = #"{"data":{"label":"Symphony","usage":1.5,"limit":10,"limit_remaining":8.5,"is_free_tier":false}}"#
    private let modelsBody = #"{"data":[{"id":"a/one","name":"One","supported_parameters":["tools"]},{"id":"b/two","name":"Two"}]}"#

    private func check(_ responses: [URL: (status: Int, body: String)]) -> (ProviderKeyCheck, StubOpenRouterTransport) {
        let transport = StubOpenRouterTransport()
        transport.responses = responses
        return (ProviderKeyCheck(openRouter: OpenRouterClient(transport: transport), openCodeGo: OpenCodeGoClient(transport: transport)), transport)
    }

    func testOpenRouterPassesWithItsKeyAndModels() async {
        let (check, transport) = check([openRouterKeyURL: (200, keyBody), openRouterModelsURL: (200, modelsBody)])
        let result = await check.test("sk-or-v1-a", provider: "openrouter")
        XCTAssertEqual(result, .works("Connected as Symphony: $1.50 used of a $10.00 limit, $8.50 left · 2 models, 1 supports tools"))
        XCTAssertTrue(result.passed)
        XCTAssertEqual(result.word, "Works")
        XCTAssertEqual(Set(transport.requests.compactMap(\.url)), [openRouterKeyURL, openRouterModelsURL])

        // The models list failing still passes on the key.
        let (keyOnly, _) = self.check([openRouterKeyURL: (200, keyBody)])
        let passed = await keyOnly.test("sk-or-v1-a", provider: "openrouter")
        XCTAssertEqual(passed, .works("Connected as Symphony: $1.50 used of a $10.00 limit, $8.50 left"))
    }

    func testOpenRouterFailsOnARejectedKey() async {
        let (check, _) = check([openRouterKeyURL: (401, "{}"), openRouterModelsURL: (200, modelsBody)])
        let result = await check.test("sk-or-v1-bad", provider: "openrouter")
        XCTAssertEqual(result, .fails(OpenRouterFailure.rejectedKey.message))
        XCTAssertFalse(result.passed)
        XCTAssertEqual(result.word, "Failed")
        XCTAssertEqual(result.detail, OpenRouterFailure.rejectedKey.message)
    }

    func testOpenCodeGoReadsItsModelsListWithTheKey() async throws {
        let (check, transport) = check([openCodeGoModelsURL: (200, #"{"object":"list","data":[{"id":"kimi-k3"},{"id":"glm-5"}]}"#)])
        let result = await check.test(" sk-go-a ", provider: "opencode-go")
        XCTAssertEqual(result, .works("OpenCode Go accepted the key · 2 models"))
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.httpMethod, "GET", "a list, never a paid call")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-go-a")
        XCTAssertEqual(transport.requests.count, 1)

        let (one, _) = self.check([openCodeGoModelsURL: (200, #"{"data":[{"id":"kimi-k3"}]}"#)])
        let single = await one.test("sk-go-a", provider: "opencode-go")
        XCTAssertEqual(single, .works("OpenCode Go accepted the key · 1 model"))
    }

    func testOpenCodeGoFailures() async {
        let cases: [(Int, String, String)] = [
            (401, "{}", OpenCodeGoClient.rejectedKey.message),
            (403, "{}", OpenCodeGoClient.rejectedKey.message),
            (429, "{}", OpenCodeGoClient.rateLimited.message),
            (500, "{}", "OpenCode Go answered with HTTP 500."),
            (200, "not json", OpenCodeGoClient.unreadable.message),
        ]
        for (status, body, message) in cases {
            let (check, _) = check([openCodeGoModelsURL: (status, body)])
            let result = await check.test("sk-go", provider: "opencode-go")
            XCTAssertEqual(result, .fails(message), "HTTP \(status)")
        }
        let (unreachable, transport) = check([:])
        let offline = await unreachable.test("sk-go", provider: "opencode-go")
        XCTAssertEqual(offline, .fails(OpenCodeGoClient.unreachable.message))
        let blank = await unreachable.test("  ", provider: "opencode-go")
        XCTAssertEqual(blank, .fails(OpenCodeGoClient.missingKey.message))
        XCTAssertEqual(transport.requests.count, 1, "a blank key is never sent")
        let none = await unreachable.test("sk", provider: "anthropic")
        XCTAssertEqual(none, .fails("This provider takes no key."))
    }

    func testTheQAStubAnswersOpenCodeGoUnderItsAPIBase() {
        let base = OpenCodeGoClient.baseURL(stub: URL(string: "http://127.0.0.1:4100/api")!)
        XCTAssertEqual(OpenCodeGoClient(baseURL: base).modelsRequest(apiKey: "k").url?.absoluteString, "http://127.0.0.1:4100/api/opencode-go/v1/models")
    }
}
