import Foundation

/// Sends an HTTP request to Linear; `URLSessionLinearTransport` in the app, a stub in tests.
public protocol LinearTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Sends Linear requests with a session that keeps no cache or cookies, so nothing about the key is stored.
public struct URLSessionLinearTransport: LinearTransport {
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

/// A Linear project a repo's route can name.
public struct LinearProject: Equatable, Identifiable {
    public var id: String
    public var name: String
    /// Keys of the teams the project belongs to, for example `["ENG"]`.
    public var teamKeys: [String]

    public init(id: String, name: String, teamKeys: [String] = []) {
        self.id = id
        self.name = name
        self.teamKeys = teamKeys
    }
}

/// A Linear issue label a repo's route can require. Group labels are left out: an issue can't carry them.
public struct LinearLabel: Equatable, Identifiable {
    public var id: String
    public var name: String
    /// Key of the team the label belongs to, nil for a workspace label.
    public var teamKey: String?

    public init(id: String, name: String, teamKey: String? = nil) {
        self.id = id
        self.name = name
        self.teamKey = teamKey
    }

    /// The names of the labels an issue in `project` can carry: workspace labels and its teams' labels, each name
    /// once, sorted. Every label when no project is picked.
    public static func names(_ labels: [LinearLabel], for project: LinearProject?) -> [String] {
        let usable = labels.filter { label in
            guard let project, let team = label.teamKey else { return true }
            return project.teamKeys.contains(team)
        }
        return Set(usable.map(\.name)).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}

/// Why a Linear call failed, as shown in the Add Repo sheet. Never holds the key.
public struct LinearFailure: Error, Equatable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public static let missingKey = LinearFailure("LINEAR_API_KEY isn't set. Add it in Settings to list Linear projects.")
    public static let unreachable = LinearFailure("Couldn't reach Linear. Check the network connection.")
    public static let rejectedKey = LinearFailure("Linear rejected LINEAR_API_KEY. Check the key in Settings.")
    public static let rateLimited = LinearFailure("Linear's rate limit is reached; try again in a minute.")
    public static let unreadable = LinearFailure("Linear's answer couldn't be read.")

    public static func httpStatus(_ status: Int) -> LinearFailure {
        LinearFailure("Linear answered with HTTP \(status).")
    }

    public static func graphQL(_ message: String) -> LinearFailure {
        LinearFailure("Linear reported an error: \(message)")
    }
}

/// Lists the projects and labels of the Linear workspace an API key belongs to, through Linear's GraphQL API.
public struct LinearClient {
    public static let endpoint = URL(string: "https://api.linear.app/graphql")!
    public static let timeout: TimeInterval = 20
    /// Items asked for per page, Linear's maximum.
    static let pageSize = 250
    /// Most pages read per list, so a huge workspace can't keep the sheet loading for long.
    static let maxPages = 20

    static let projectsQuery = """
        query SymphonyBarProjects($first: Int!, $after: String) {
          projects(first: $first, after: $after) {
            nodes { id name teams { nodes { key } } }
            pageInfo { hasNextPage endCursor }
          }
        }
        """

    static let labelsQuery = """
        query SymphonyBarLabels($first: Int!, $after: String) {
          issueLabels(first: $first, after: $after) {
            nodes { id name isGroup team { key } }
            pageInfo { hasNextPage endCursor }
          }
        }
        """

    private let apiKey: String
    private let transport: LinearTransport
    private let endpoint: URL

    public init(apiKey: String, transport: LinearTransport = URLSessionLinearTransport(), endpoint: URL = LinearClient.endpoint) {
        self.apiKey = apiKey.trimmingWhitespace()
        self.transport = transport
        self.endpoint = endpoint
    }

    /// The workspace's projects, sorted by name.
    public func projects() async -> Result<[LinearProject], LinearFailure> {
        await fetchAll(Self.projectsQuery, as: ProjectsData.self) { $0.projects }.map { nodes in
            nodes
                .map { LinearProject(id: $0.id, name: $0.name, teamKeys: $0.teams?.nodes.map(\.key) ?? []) }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    /// The workspace's labels an issue can carry, sorted by name.
    public func labels() async -> Result<[LinearLabel], LinearFailure> {
        await fetchAll(Self.labelsQuery, as: LabelsData.self) { $0.issueLabels }.map { nodes in
            nodes
                .filter { !($0.isGroup ?? false) }
                .map { LinearLabel(id: $0.id, name: $0.name, teamKey: $0.team?.key) }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    /// A GraphQL POST with the key as Linear expects a personal API key: bare, without `Bearer`.
    public func request(query: String, after cursor: String?) -> URLRequest {
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Self.timeout)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        var variables: [String: Any] = ["first": Self.pageSize]
        if let cursor { variables["after"] = cursor }
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["query": query, "variables": variables], options: [.sortedKeys])
        return request
    }

    /// Reads every page of one connection, up to `maxPages`.
    private func fetchAll<Payload: Decodable, Node: Decodable>(
        _ query: String,
        as type: Payload.Type,
        connection: (Payload) -> Connection<Node>?
    ) async -> Result<[Node], LinearFailure> {
        guard !apiKey.isEmpty else { return .failure(.missingKey) }
        var nodes: [Node] = []
        var cursor: String?
        for _ in 0..<Self.maxPages {
            let page: Connection<Node>
            switch await fetch(request(query: query, after: cursor), as: type) {
            case let .success(data):
                guard let found = connection(data) else { return .failure(.unreadable) }
                page = found
            case let .failure(failure):
                return .failure(failure)
            }
            nodes += page.nodes
            guard page.pageInfo?.hasNextPage == true, let next = page.pageInfo?.endCursor else { break }
            cursor = next
        }
        return .success(nodes)
    }

    private func fetch<Payload: Decodable>(_ request: URLRequest, as type: Payload.Type) async -> Result<Payload, LinearFailure> {
        guard let (body, response) = try? await transport.send(request) else { return .failure(.unreachable) }
        return Self.parse(body, statusCode: response.statusCode, as: type)
    }

    /// Turns a GraphQL response into its data or the failure it reports. Linear answers a bad key and the rate limit
    /// with GraphQL errors as well as an HTTP status, so both are read.
    static func parse<Payload: Decodable>(_ body: Data, statusCode: Int, as type: Payload.Type) -> Result<Payload, LinearFailure> {
        let payload = try? JSONDecoder().decode(Response<Payload>.self, from: body)
        let errors = payload?.errors ?? []
        let codes = errors.compactMap { $0.extensions?.code?.uppercased() }
        if statusCode == 401 || statusCode == 403 || codes.contains("AUTHENTICATION_ERROR") { return .failure(.rejectedKey) }
        if statusCode == 429 || codes.contains("RATELIMITED") { return .failure(.rateLimited) }
        if let message = errors.first.map({ $0.message ?? "unknown error" }) { return .failure(.graphQL(message)) }
        guard statusCode == 200 else { return .failure(.httpStatus(statusCode)) }
        guard let data = payload?.data else { return .failure(.unreadable) }
        return .success(data)
    }

    // MARK: Payloads

    private struct Response<Payload: Decodable>: Decodable {
        let data: Payload?
        let errors: [GraphQLError]?
    }

    private struct GraphQLError: Decodable {
        struct Extensions: Decodable {
            let code: String?
        }

        let message: String?
        let extensions: Extensions?
    }

    struct Connection<Node: Decodable>: Decodable {
        struct PageInfo: Decodable {
            let hasNextPage: Bool?
            let endCursor: String?
        }

        let nodes: [Node]
        let pageInfo: PageInfo?
    }

    struct TeamKey: Decodable {
        let key: String
    }

    struct ProjectsData: Decodable {
        struct Project: Decodable {
            let id: String
            let name: String
            let teams: Connection<TeamKey>?
        }

        let projects: Connection<Project>?
    }

    struct LabelsData: Decodable {
        struct Label: Decodable {
            let id: String
            let name: String
            let isGroup: Bool?
            let team: TeamKey?
        }

        let issueLabels: Connection<Label>?
    }
}
