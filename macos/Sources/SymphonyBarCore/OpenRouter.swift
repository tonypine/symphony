import Foundation

/// Sends an HTTP request to OpenRouter; `URLSessionOpenRouterTransport` in the app, a stub in tests.
public protocol OpenRouterTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Sends OpenRouter requests with a session that keeps no cache or cookies, so nothing about the key is stored.
public struct URLSessionOpenRouterTransport: OpenRouterTransport {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

/// What `GET /api/v1/key` says about an API key. Amounts are in US dollars of credit.
public struct OpenRouterKeyInfo: Equatable {
    public var label: String
    public var usage: Double
    /// Nil when the key has no credit limit.
    public var limit: Double?
    public var limitRemaining: Double?
    public var isFreeTier: Bool

    public init(label: String, usage: Double, limit: Double?, limitRemaining: Double?, isFreeTier: Bool) {
        self.label = label
        self.usage = usage
        self.limit = limit
        self.limitRemaining = limitRemaining
        self.isFreeTier = isFreeTier
    }

    /// The success line Settings shows, for example "Connected as Symphony: $12.50 used of a $100.00 limit".
    public var summary: String {
        let used = Self.dollars(usage)
        let credit: String
        if let limit {
            let remaining = limitRemaining.map { ", \(Self.dollars($0)) left" } ?? ""
            credit = "\(used) used of a \(Self.dollars(limit)) limit\(remaining)"
        } else {
            credit = "\(used) used, no credit limit"
        }
        return "Connected as \(label): \(credit)" + (isFreeTier ? " (free tier)" : "")
    }

    static func dollars(_ amount: Double) -> String {
        String(format: "$%.2f", amount)
    }
}

/// One model from `GET /api/v1/models`.
public struct OpenRouterModel: Equatable {
    public var id: String
    public var name: String
    /// True when the model accepts the `tools` parameter, which agent runs need.
    public var supportsTools: Bool

    public init(id: String, name: String, supportsTools: Bool) {
        self.id = id
        self.name = name
        self.supportsTools = supportsTools
    }

    /// "312 models, 141 support tools".
    public static func summary(_ models: [OpenRouterModel]) -> String {
        let tools = models.filter(\.supportsTools).count
        let noun = models.count == 1 ? "model" : "models"
        let verb = tools == 1 ? "supports" : "support"
        return "\(models.count) \(noun), \(tools) \(verb) tools"
    }
}

/// Why an OpenRouter call failed, as shown in Settings. Never holds the key.
public struct OpenRouterFailure: Error, Equatable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public static let missingKey = OpenRouterFailure("Enter an OpenRouter API key first.")
    public static let unreachable = OpenRouterFailure("Couldn't reach OpenRouter. Check the network connection.")
    public static let rejectedKey = OpenRouterFailure("OpenRouter rejected the key. Check that it is correct and active.")
    public static let rateLimited = OpenRouterFailure("OpenRouter's rate limit is reached; try again in a minute.")
    public static let unreadable = OpenRouterFailure("OpenRouter's answer couldn't be read.")

    public static func httpStatus(_ status: Int) -> OpenRouterFailure {
        OpenRouterFailure("OpenRouter answered with HTTP \(status).")
    }
}

/// Talks to the OpenRouter API: checks a key and lists the models.
public struct OpenRouterClient {
    public static let baseURL = URL(string: "https://openrouter.ai/api/v1/")!
    public static let timeout: TimeInterval = 20

    private let transport: OpenRouterTransport
    private let baseURL: URL

    public init(transport: OpenRouterTransport = URLSessionOpenRouterTransport(), baseURL: URL = OpenRouterClient.baseURL) {
        self.transport = transport
        self.baseURL = baseURL
    }

    /// `GET /key` with the key as a bearer token.
    public func keyRequest(apiKey: String) -> URLRequest {
        var request = request(path: "key")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// `GET /models`, which needs no key.
    public func modelsRequest() -> URLRequest {
        request(path: "models")
    }

    /// Checks `apiKey` and returns what OpenRouter knows about it.
    public func checkKey(_ apiKey: String) async -> Result<OpenRouterKeyInfo, OpenRouterFailure> {
        let apiKey = apiKey.trimmingWhitespace()
        guard !apiKey.isEmpty else { return .failure(.missingKey) }
        return await fetch(keyRequest(apiKey: apiKey)).flatMap(Self.parseKey)
    }

    /// Lists every model OpenRouter offers.
    public func models() async -> Result<[OpenRouterModel], OpenRouterFailure> {
        await fetch(modelsRequest()).flatMap(Self.parseModels)
    }

    public static func parseKey(_ data: Data) -> Result<OpenRouterKeyInfo, OpenRouterFailure> {
        guard let payload = try? JSONDecoder().decode(KeyPayload.self, from: data) else { return .failure(.unreadable) }
        let key = payload.data
        return .success(
            OpenRouterKeyInfo(
                label: key.label ?? "unnamed key",
                usage: key.usage ?? 0,
                limit: key.limit,
                limitRemaining: key.limitRemaining,
                isFreeTier: key.isFreeTier ?? false
            )
        )
    }

    public static func parseModels(_ data: Data) -> Result<[OpenRouterModel], OpenRouterFailure> {
        guard let payload = try? JSONDecoder().decode(ModelsPayload.self, from: data) else {
            return .failure(.unreadable)
        }
        return .success(
            payload.data.map { model in
                OpenRouterModel(
                    id: model.id,
                    name: model.name ?? model.id,
                    supportsTools: model.supportedParameters?.contains("tools") ?? false
                )
            }
        )
    }

    private func request(path: String) -> URLRequest {
        var request = URLRequest(
            url: baseURL.appendingPathComponent(path),
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: Self.timeout
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func fetch(_ request: URLRequest) async -> Result<Data, OpenRouterFailure> {
        guard let (data, response) = try? await transport.send(request) else { return .failure(.unreachable) }
        switch response.statusCode {
        case 200:
            return .success(data)
        case 401, 403:
            return .failure(.rejectedKey)
        case 429:
            return .failure(.rateLimited)
        default:
            return .failure(.httpStatus(response.statusCode))
        }
    }

    private struct KeyPayload: Decodable {
        struct Key: Decodable {
            let label: String?
            let usage: Double?
            let limit: Double?
            let limitRemaining: Double?
            let isFreeTier: Bool?

            enum CodingKeys: String, CodingKey {
                case label, usage, limit
                case limitRemaining = "limit_remaining"
                case isFreeTier = "is_free_tier"
            }
        }

        let data: Key
    }

    private struct ModelsPayload: Decodable {
        struct Model: Decodable {
            let id: String
            let name: String?
            let supportedParameters: [String]?

            enum CodingKeys: String, CodingKey {
                case id, name
                case supportedParameters = "supported_parameters"
            }
        }

        let data: [Model]
    }
}
