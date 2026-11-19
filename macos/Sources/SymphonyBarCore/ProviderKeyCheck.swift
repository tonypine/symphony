import Foundation

/// Test connection on a provider's page (TP-1540): the cheapest call that proves a key works, never a paid one.
/// OpenRouter's reads its key and models API, as Settings did; OpenCode Go's reads its models list with the key.
public struct ProviderKeyCheck {
    /// What the test found, as the page's one-line Situation line shows it.
    public enum Result: Equatable {
        case works(String)
        case fails(String)

        public var passed: Bool { if case .works = self { true } else { false } }

        /// The line's word: "Works" or "Failed".
        public var word: String { passed ? "Works" : "Failed" }

        public var detail: String {
            switch self {
            case .works(let detail), .fails(let detail): detail
            }
        }
    }

    private let openRouter: OpenRouterClient
    private let openCodeGo: OpenCodeGoClient

    public init(openRouter: OpenRouterClient = OpenRouterClient(), openCodeGo: OpenCodeGoClient = OpenCodeGoClient()) {
        self.openRouter = openRouter
        self.openCodeGo = openCodeGo
    }

    /// Tests `key` on the provider `id`.
    public func test(_ key: String, provider id: String) async -> Result {
        switch id {
        case ProviderKeys.openRouter.id:
            let keyResult = await openRouter.checkKey(key)
            switch keyResult {
            case .failure(let failure): return .fails(failure.message)
            case .success(let info):
                let summary = (try? await openRouter.models().get()).map { " · " + OpenRouterModel.summary($0) } ?? ""
                return .works(info.summary + summary)
            }
        case ProviderKeys.openCodeGo.id:
            switch await openCodeGo.models(key) {
            case .failure(let failure): return .fails(failure.message)
            case .success(let count): return .works("OpenCode Go accepted the key · \(count) \(count == 1 ? "model" : "models")")
            }
        default:
            return .fails("This provider takes no key.")
        }
    }
}

/// Talks to OpenCode Go's OpenAI-compatible API (the base Codex runs reach it on): `GET models` with the key, which
/// costs nothing and answers 401 to a key it doesn't know.
public struct OpenCodeGoClient {
    public static let baseURL = URL(string: "https://opencode.ai/inference/go/openai/v1/")!

    private let transport: OpenRouterTransport
    private let baseURL: URL

    public init(transport: OpenRouterTransport = URLSessionOpenRouterTransport(), baseURL: URL = OpenCodeGoClient.baseURL) {
        self.transport = transport
        self.baseURL = baseURL
    }

    /// The client's base URL on the QA stub, whose OpenRouter API base is `api` (`http://127.0.0.1:4100/api`): the stub
    /// answers OpenCode Go's models list under `opencode-go/v1`.
    public static func baseURL(stub api: URL) -> URL {
        api.appendingPathComponent("opencode-go/v1", isDirectory: true)
    }

    /// `GET models` with `apiKey` as a bearer token.
    public func modelsRequest(apiKey: String) -> URLRequest {
        var request = URLRequest(
            url: baseURL.appendingPathComponent("models"), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: OpenRouterClient.timeout
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// How many models OpenCode Go lists for `apiKey`, or why it couldn't say.
    public func models(_ apiKey: String) async -> Result<Int, OpenRouterFailure> {
        let apiKey = apiKey.trimmingWhitespace()
        guard !apiKey.isEmpty else { return .failure(Self.missingKey) }
        guard let (data, response) = try? await transport.send(modelsRequest(apiKey: apiKey)) else { return .failure(Self.unreachable) }
        switch response.statusCode {
        case 200:
            guard let payload = try? JSONDecoder().decode(ModelsPayload.self, from: data) else { return .failure(Self.unreadable) }
            return .success(payload.data.count)
        case 401, 403: return .failure(Self.rejectedKey)
        case 429: return .failure(Self.rateLimited)
        default: return .failure(OpenRouterFailure("OpenCode Go answered with HTTP \(response.statusCode)."))
        }
    }

    public static let missingKey = OpenRouterFailure("Enter an OpenCode Go API key first.")
    public static let unreachable = OpenRouterFailure("Couldn't reach OpenCode Go. Check the network connection.")
    public static let rejectedKey = OpenRouterFailure("OpenCode Go rejected the key. Check that it is correct and active.")
    public static let rateLimited = OpenRouterFailure("OpenCode Go's rate limit is reached; try again in a minute.")
    public static let unreadable = OpenRouterFailure("OpenCode Go's answer couldn't be read.")

    private struct ModelsPayload: Decodable {
        struct Model: Decodable { let id: String }
        let data: [Model]
    }
}
