import XCTest
@testable import SymphonyBarCore

/// Linear's documented query complexity, estimated high: a scalar field costs 0.1 points, an object 1, and a
/// connection multiplies what it holds by its page size, `first`, or 50 when a `nodes` list has none. It multiplies
/// `pageInfo` too, so a query under this estimate is under Linear's own count.
struct LinearQueryComplexity {
    var points: Double
    /// Most connections nested in one another.
    var connectionDepth: Int

    private enum Token: Equatable {
        case name(String)
        case args(String)
        case open
        case close
    }

    init(_ query: String, variables: [String: Any]) {
        let tokens = Self.tokens(query)
        var index = (tokens.firstIndex(of: .open) ?? tokens.endIndex) + 1
        let set = Self.selectionSet(tokens, &index, variables)
        points = set.points
        connectionDepth = set.depth
    }

    /// The fields from `index` to the `}` closing their set, which it steps past.
    private static func selectionSet(
        _ tokens: [Token],
        _ index: inout Int,
        _ variables: [String: Any]
    ) -> (points: Double, depth: Int, names: Set<String>) {
        var points = 0.0
        var depth = 0
        var names: Set<String> = []
        while index < tokens.count, case let .name(name) = tokens[index] {
            names.insert(name)
            index += 1
            var args = ""
            if index < tokens.count, case let .args(text) = tokens[index] {
                args = text
                index += 1
            }
            guard index < tokens.count, tokens[index] == .open else {
                points += 0.1
                continue
            }
            index += 1
            let children = selectionSet(tokens, &index, variables)
            let pageSize = Self.pageSize(args, variables) ?? (children.names.contains("nodes") ? 50 : nil)
            points += 1 + Double(pageSize ?? 1) * children.points
            depth = max(depth, children.depth + (pageSize == nil ? 0 : 1))
        }
        index += 1
        return (points, depth, names)
    }

    /// The `first` argument, a literal or a variable.
    private static func pageSize(_ args: String, _ variables: [String: Any]) -> Int? {
        guard let match = args.range(of: #"first\s*:\s*\$?\w+"#, options: .regularExpression) else { return nil }
        let value = args[match].split(separator: ":")[1].trimmingCharacters(in: .whitespaces)
        return value.hasPrefix("$") ? variables[String(value.dropFirst())] as? Int : Int(value)
    }

    private static func tokens(_ query: String) -> [Token] {
        var tokens: [Token] = []
        var index = query.startIndex
        while index < query.endIndex {
            let char = query[index]
            if char == "{" || char == "}" {
                tokens.append(char == "{" ? .open : .close)
                index = query.index(after: index)
            } else if char == "(" {
                var depth = 0
                var end = index
                repeat {
                    if query[end] == "(" { depth += 1 } else if query[end] == ")" { depth -= 1 }
                    end = query.index(after: end)
                } while depth > 0 && end < query.endIndex
                tokens.append(.args(String(query[index..<end])))
                index = end
            } else if char.isLetter || char == "_" {
                var end = index
                while end < query.endIndex, query[end].isLetter || query[end].isNumber || query[end] == "_" {
                    end = query.index(after: end)
                }
                tokens.append(.name(String(query[index..<end])))
                index = end
            } else {
                index = query.index(after: index)
            }
        }
        return tokens
    }
}

final class LinearQueryComplexityTests: XCTestCase {
    /// Linear's limit for one query.
    private static let linearLimit = 10_000.0
    /// What the Add Repo sheet's queries may cost each: a fiftieth of Linear's limit.
    private static let budget = 200.0

    /// The projects query before TP-693: 250 projects a page, each with its teams' default page of 50.
    private static let nestedProjectsQuery = """
        query SymphonyBarProjects($first: Int!, $after: String) {
          projects(first: $first, after: $after) {
            nodes { id name teams { nodes { key } } }
            pageInfo { hasNextPage endCursor }
          }
        }
        """

    func testTheEstimateFollowsLinearsRules() {
        let query = "query Q($first: Int!) { viewer { id name } teams(first: $first) { nodes { id } } issues { nodes { id } } }"

        let complexity = LinearQueryComplexity(query, variables: ["first": 10])

        // viewer 1 + 0.2; teams 1 + 10 × (1 + 0.1); issues 1 + 50 × (1 + 0.1).
        XCTAssertEqual(complexity.points, 1.2 + 12 + 56, accuracy: 0.001)
        XCTAssertEqual(complexity.connectionDepth, 1)
    }

    func testTheOldNestedProjectsQueryIsOverLinearsLimit() {
        let complexity = LinearQueryComplexity(Self.nestedProjectsQuery, variables: ["first": 250])

        XCTAssertGreaterThan(complexity.points, Self.linearLimit)
        XCTAssertEqual(complexity.connectionDepth, 2)
    }

    func testEveryQueryTheClientSendsStaysWithinTheBudget() async throws {
        let transport = StubLinearTransport()
        transport.responses = [
            (200, #"{"data":{"projects":{"nodes":[{"id":"p1","name":"A"}],"pageInfo":{"hasNextPage":true,"endCursor":"c1"}}}}"#),
            (200, #"{"data":{"projects":{"nodes":[{"id":"p2","name":"B"}],"pageInfo":{"hasNextPage":false}}}}"#),
            (200, #"{"data":{"project":{"teams":{"nodes":[{"id":"t1"}],"pageInfo":{"hasNextPage":false}}}}}"#),
            (200, #"{"data":{"issueLabels":{"nodes":[{"id":"l1","name":"Bug"}],"pageInfo":{"hasNextPage":false}}}}"#),
            (200, #"{"data":{"issueLabels":{"nodes":[{"id":"l1","name":"Bug"}],"pageInfo":{"hasNextPage":false}}}}"#),
        ]
        let client = LinearClient(apiKey: "lin_api_abc", transport: transport)

        _ = await client.projects()
        _ = await client.labels(forProject: "p1")
        _ = await client.labels(forProject: nil)

        XCTAssertEqual(LinearClient.pageSize, 50)
        XCTAssertEqual(transport.requests.count, 5)
        for request in transport.requests {
            let data = try XCTUnwrap(request.httpBody)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let query = try XCTUnwrap(json["query"] as? String)
            let variables = try XCTUnwrap(json["variables"] as? [String: Any])

            let complexity = LinearQueryComplexity(query, variables: variables)

            XCTAssertEqual(variables["first"] as? Int, 50, query)
            XCTAssertEqual(complexity.connectionDepth, 1, query)
            XCTAssertLessThanOrEqual(complexity.points, Self.budget, query)
        }
    }

    func testLinearsQueryTooComplexErrorReadsPlainly() async {
        let body = """
            {"errors":[{"message":"Query too complex","extensions":{"type":"invalid input","code":"INPUT_ERROR",
            "statusCode":400,"userError":true,
            "userPresentableMessage":"Query too complex - complexity is 14601, maximum allowed is 10000"}}]}
            """
        let transport = StubLinearTransport()
        transport.responses = [(400, body)]
        let client = LinearClient(apiKey: "lin_api_abc", transport: transport)

        let result = await client.projects()

        // The sheet shows the failure's message as it is.
        XCTAssertEqual(result, .failure(.tooComplex))
        XCTAssertEqual(
            LinearFailure.tooComplex.message,
            "Linear turned the request down as too large to answer at once. Retry, and report it if it keeps happening."
        )
        for raw in ["Query", "complexity", "GraphQL", "INPUT_ERROR", "{"] {
            XCTAssertFalse(LinearFailure.tooComplex.message.contains(raw), raw)
        }
    }
}
