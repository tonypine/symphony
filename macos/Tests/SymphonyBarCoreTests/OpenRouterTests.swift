import XCTest
@testable import SymphonyBarCore

/// Answers OpenRouter requests from canned responses keyed by URL, and records every request.
final class StubOpenRouterTransport: OpenRouterTransport {
    var responses: [URL: (status: Int, body: String)] = [:]
    var requests: [URLRequest] = []

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard let url = request.url, let response = responses[url] else { throw URLError(.notConnectedToInternet) }
        let http = HTTPURLResponse(url: url, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: nil)!
        return (Data(response.body.utf8), http)
    }
}

final class OpenRouterTests: XCTestCase {
    private let keyURL = URL(string: "https://openrouter.ai/api/v1/key")!
    private let modelsURL = URL(string: "https://openrouter.ai/api/v1/models")!

    private func client(_ responses: [URL: (status: Int, body: String)] = [:]) -> (OpenRouterClient, StubOpenRouterTransport) {
        let transport = StubOpenRouterTransport()
        transport.responses = responses
        return (OpenRouterClient(transport: transport), transport)
    }

    func testKeyRequestSendsTheKeyAsABearerToken() {
        let request = OpenRouterClient().keyRequest(apiKey: "sk-or-v1-abc")

        XCTAssertEqual(request.url, keyURL)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-or-v1-abc")
        XCTAssertEqual(OpenRouterClient().modelsRequest().url, modelsURL)
        XCTAssertNil(OpenRouterClient().modelsRequest().value(forHTTPHeaderField: "Authorization"))
    }

    func testAStubAPIBaseGetsTheSamePaths() {
        let base = OpenRouterClient.baseURL(api: URL(string: "http://127.0.0.1:4100/api")!)
        let stub = OpenRouterClient(baseURL: base)

        XCTAssertEqual(base.absoluteString, "http://127.0.0.1:4100/api/v1/")
        XCTAssertEqual(stub.keyRequest(apiKey: "sk-or-v1-symphony-qa-stub").url?.absoluteString, "http://127.0.0.1:4100/api/v1/key")
        XCTAssertEqual(stub.modelsRequest().url?.absoluteString, "http://127.0.0.1:4100/api/v1/models")
    }

    func testValidKeyWithALimitReportsLabelAndCredit() async {
        let body = """
            {"data":{"label":"sk-or-v1-abc...xyz","usage":12.5,"limit":100,"limit_remaining":87.5,
             "is_free_tier":false,"rate_limit":{"requests":10,"interval":"10s"}}}
            """
        let (client, transport) = client([keyURL: (200, body)])

        let result = await client.checkKey(" sk-or-v1-abc\n")

        let info = OpenRouterKeyInfo(label: "sk-or-v1-abc...xyz", usage: 12.5, limit: 100, limitRemaining: 87.5, isFreeTier: false)
        XCTAssertEqual(result, .success(info))
        XCTAssertEqual(info.summary, "Connected as sk-or-v1-abc...xyz: $12.50 used of a $100.00 limit, $87.50 left")
        XCTAssertEqual(transport.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer sk-or-v1-abc")
    }

    func testValidKeyWithoutALimitSaysSo() async {
        let body = #"{"data":{"label":"Symphony","usage":0.004,"limit":null,"limit_remaining":null,"is_free_tier":true}}"#
        let (client, _) = client([keyURL: (200, body)])

        guard case let .success(info) = await client.checkKey("sk-or-v1-abc") else { return XCTFail("expected success") }

        XCTAssertNil(info.limit)
        XCTAssertEqual(info.summary, "Connected as Symphony: $0.00 used, no credit limit (free tier)")
    }

    func testMissingFieldsFallBackToDefaults() {
        let parsed = OpenRouterClient.parseKey(Data(#"{"data":{}}"#.utf8))
        XCTAssertEqual(
            parsed,
            .success(OpenRouterKeyInfo(label: "unnamed key", usage: 0, limit: nil, limitRemaining: nil, isFreeTier: false))
        )
        let limited = OpenRouterKeyInfo(label: "k", usage: 1, limit: 5, limitRemaining: nil, isFreeTier: false)
        XCTAssertEqual(limited.summary, "Connected as k: $1.00 used of a $5.00 limit")
    }

    func testRejectedKeyIsReported() async {
        let body = #"{"error":{"message":"No auth credentials found","code":401}}"#
        for status in [401, 403] {
            let (client, _) = client([keyURL: (status, body)])
            let result = await client.checkKey("sk-or-v1-wrong")
            XCTAssertEqual(result, .failure(.rejectedKey))
        }
        XCTAssertTrue(OpenRouterFailure.rejectedKey.message.contains("rejected the key"))
    }

    func testNetworkAndServerFailuresAreReported() async {
        let (offline, _) = client()
        let unreachable = await offline.checkKey("sk-or-v1-abc")
        XCTAssertEqual(unreachable, .failure(.unreachable))

        let (limited, _) = client([keyURL: (429, "")])
        let rateLimited = await limited.checkKey("sk-or-v1-abc")
        XCTAssertEqual(rateLimited, .failure(.rateLimited))

        let (broken, _) = client([keyURL: (502, "")])
        let serverError = await broken.checkKey("sk-or-v1-abc")
        XCTAssertEqual(serverError, .failure(.httpStatus(502)))
        XCTAssertEqual(OpenRouterFailure.httpStatus(502).message, "OpenRouter answered with HTTP 502.")

        let (garbled, _) = client([keyURL: (200, "<html>")])
        let unreadable = await garbled.checkKey("sk-or-v1-abc")
        XCTAssertEqual(unreadable, .failure(.unreadable))
    }

    func testBlankKeyIsNotSent() async {
        let (client, transport) = client()

        let result = await client.checkKey("  ")

        XCTAssertEqual(result, .failure(.missingKey))
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testFailureMessagesNeverHoldTheKey() async {
        let key = "sk-or-v1-TOP-SECRET"
        for status in [401, 429, 500] {
            let (client, _) = client([keyURL: (status, key)])
            guard case let .failure(failure) = await client.checkKey(key) else { return XCTFail("expected failure") }
            XCTAssertFalse(failure.message.contains(key))
        }
    }

    func testModelsAreParsedAndFilteredForTools() async {
        let body = """
            {"data":[
              {"id":"anthropic/claude-sonnet-4","name":"Anthropic: Claude Sonnet 4",
               "supported_parameters":["max_tokens","tools","tool_choice","reasoning"]},
              {"id":"openai/gpt-4o","name":"OpenAI: GPT-4o","supported_parameters":["tools"]},
              {"id":"some/text-only","name":"Text only","supported_parameters":["temperature"]},
              {"id":"some/bare"}
            ]}
            """
        let (client, _) = client([modelsURL: (200, body)])

        guard case let .success(models) = await client.models() else { return XCTFail("expected models") }

        XCTAssertEqual(
            models,
            [
                OpenRouterModel(
                    id: "anthropic/claude-sonnet-4", name: "Anthropic: Claude Sonnet 4", supportsTools: true, supportsReasoning: true
                ),
                OpenRouterModel(id: "openai/gpt-4o", name: "OpenAI: GPT-4o", supportsTools: true),
                OpenRouterModel(id: "some/text-only", name: "Text only", supportsTools: false),
                OpenRouterModel(id: "some/bare", name: "some/bare", supportsTools: false),
            ]
        )
        XCTAssertEqual(models.filter(\.supportsTools).map(\.id), ["anthropic/claude-sonnet-4", "openai/gpt-4o"])
        XCTAssertEqual(OpenRouterModel.summary(models), "4 models, 2 support tools")
    }

    func testToolModelsMatchIdOrNameAndSortByName() {
        let models = [
            OpenRouterModel(id: "openai/gpt-4o", name: "OpenAI: GPT-4o", supportsTools: true),
            OpenRouterModel(id: "anthropic/claude-sonnet-4", name: "Anthropic: Claude Sonnet 4", supportsTools: true),
            OpenRouterModel(id: "anthropic/claude-2", name: "Anthropic: Claude 2", supportsTools: false),
        ]

        XCTAssertEqual(
            OpenRouterModel.toolModels(models, matching: "").map(\.id),
            ["anthropic/claude-sonnet-4", "openai/gpt-4o"]
        )
        XCTAssertEqual(OpenRouterModel.toolModels(models, matching: " ANTHROPIC/ ").map(\.id), ["anthropic/claude-sonnet-4"])
        XCTAssertEqual(OpenRouterModel.toolModels(models, matching: "gpt").map(\.id), ["openai/gpt-4o"])
        XCTAssertEqual(OpenRouterModel.toolModels(models, matching: "sonnet 4").map(\.id), ["anthropic/claude-sonnet-4"])
        XCTAssertEqual(OpenRouterModel.toolModels(models, matching: "claude 2"), [])
    }

    func testEffortNoteOnlyForAListedModelWithoutReasoning() {
        let models = [
            OpenRouterModel(id: "a/thinks", name: "Thinks", supportsTools: true, supportsReasoning: true),
            OpenRouterModel(id: "a/fast", name: "Fast", supportsTools: true),
        ]

        XCTAssertEqual(
            OpenRouterModel.effortNote(for: "a/fast", in: models),
            "Fast doesn't support reasoning on OpenRouter, so effort has no effect on it."
        )
        XCTAssertNil(OpenRouterModel.effortNote(for: "a/thinks", in: models))
        XCTAssertNil(OpenRouterModel.effortNote(for: "a/unknown", in: models))
        XCTAssertNil(OpenRouterModel.effortNote(for: nil, in: models))
    }

    func testModelSummaryUsesSingularForOne() {
        let one = OpenRouterModel(id: "a", name: "A", supportsTools: true)
        XCTAssertEqual(OpenRouterModel.summary([one]), "1 model, 1 supports tools")
        XCTAssertEqual(OpenRouterModel.summary([]), "0 models, 0 support tools")
    }

    func testModelsFailuresAreReported() async {
        let (offline, _) = client()
        let unreachable = await offline.models()
        XCTAssertEqual(unreachable, .failure(.unreachable))

        let (garbled, _) = client([modelsURL: (200, #"{"data":"nope"}"#)])
        let unreadable = await garbled.models()
        XCTAssertEqual(unreadable, .failure(.unreadable))
    }
}
