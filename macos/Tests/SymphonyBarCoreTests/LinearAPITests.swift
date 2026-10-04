import XCTest
@testable import SymphonyBarCore

/// Answers Linear GraphQL requests in order from canned responses, and records every request.
final class StubLinearTransport: LinearTransport {
    var responses: [(status: Int, body: String)] = []
    var requests: [URLRequest] = []

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !responses.isEmpty, let url = request.url else { throw URLError(.notConnectedToInternet) }
        let response = responses.removeFirst()
        let http = HTTPURLResponse(url: url, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: nil)!
        return (Data(response.body.utf8), http)
    }
}

final class LinearAPITests: XCTestCase {
    private func client(key: String = "lin_api_abc", _ responses: [(status: Int, body: String)]) -> (LinearClient, StubLinearTransport) {
        let transport = StubLinearTransport()
        transport.responses = responses
        return (LinearClient(apiKey: key, transport: transport), transport)
    }

    /// The JSON body of a request: its query and variables.
    private func body(_ request: URLRequest?) throws -> [String: Any] {
        let data = try XCTUnwrap(request?.httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testRequestPostsTheQueryWithTheKeyAsLinearExpects() throws {
        let request = LinearClient(apiKey: " lin_api_abc\n").request(query: LinearClient.projectsQuery, after: nil)

        XCTAssertEqual(request.url, URL(string: "https://api.linear.app/graphql"))
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "lin_api_abc")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let json = try body(request)
        XCTAssertEqual(json["query"] as? String, LinearClient.projectsQuery)
        XCTAssertEqual(json["variables"] as? [String: Int], ["first": 250])
    }

    func testListsProjectsSortedByNameWithTheirTeams() async {
        let page = """
            {"data":{"projects":{"nodes":[
              {"id":"p2","name":"web platform","teams":{"nodes":[{"key":"ENG"},{"key":"OPS"}]}},
              {"id":"p1","name":"Apps","teams":{"nodes":[]}},
              {"id":"p3","name":"Billing"}
            ],"pageInfo":{"hasNextPage":false,"endCursor":"c1"}}}}
            """
        let (client, transport) = client([(200, page)])

        let result = await client.projects()

        XCTAssertEqual(result, .success([
            LinearProject(id: "p1", name: "Apps"),
            LinearProject(id: "p3", name: "Billing"),
            LinearProject(id: "p2", name: "web platform", teamKeys: ["ENG", "OPS"]),
        ]))
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testFollowsPagesWithTheEndCursor() async throws {
        let first = #"{"data":{"projects":{"nodes":[{"id":"p1","name":"A"}],"pageInfo":{"hasNextPage":true,"endCursor":"c1"}}}}"#
        let second = #"{"data":{"projects":{"nodes":[{"id":"p2","name":"B"}],"pageInfo":{"hasNextPage":false,"endCursor":"c2"}}}}"#
        let (client, transport) = client([(200, first), (200, second)])

        let result = await client.projects()

        XCTAssertEqual(result, .success([LinearProject(id: "p1", name: "A"), LinearProject(id: "p2", name: "B")]))
        XCTAssertNil((try body(transport.requests.first)["variables"] as? [String: Any])?["after"])
        XCTAssertEqual((try body(transport.requests.last)["variables"] as? [String: Any])?["after"] as? String, "c1")
    }

    func testStopsAfterTheMostPages() async {
        let page = #"{"data":{"projects":{"nodes":[{"id":"p","name":"A"}],"pageInfo":{"hasNextPage":true,"endCursor":"c"}}}}"#
        let (client, transport) = client(Array(repeating: (200, page), count: LinearClient.maxPages + 5))

        guard case let .success(projects) = await client.projects() else { return XCTFail("expected projects") }

        XCTAssertEqual(projects.count, LinearClient.maxPages)
        XCTAssertEqual(transport.requests.count, LinearClient.maxPages)
    }

    func testListsLabelsWithoutGroupsSortedByName() async throws {
        let page = """
            {"data":{"issueLabels":{"nodes":[
              {"id":"l1","name":"frontend","isGroup":false,"team":{"key":"ENG"}},
              {"id":"l2","name":"Area","isGroup":true,"team":null},
              {"id":"l3","name":"Bug","isGroup":false,"team":null},
              {"id":"l4","name":"api"}
            ],"pageInfo":{"hasNextPage":false}}}}
            """
        let (client, transport) = client([(200, page)])

        let result = await client.labels()

        XCTAssertEqual(result, .success([
            LinearLabel(id: "l4", name: "api"),
            LinearLabel(id: "l3", name: "Bug"),
            LinearLabel(id: "l1", name: "frontend", teamKey: "ENG"),
        ]))
        XCTAssertEqual(try body(transport.requests.first)["query"] as? String, LinearClient.labelsQuery)
    }

    func testLabelNamesForAProjectKeepWorkspaceLabelsAndItsTeams() {
        let labels = [
            LinearLabel(id: "1", name: "frontend", teamKey: "ENG"),
            LinearLabel(id: "2", name: "Bug"),
            LinearLabel(id: "3", name: "bug-ops", teamKey: "OPS"),
            LinearLabel(id: "4", name: "Bug", teamKey: "ENG"),
        ]

        XCTAssertEqual(LinearLabel.names(labels, for: LinearProject(id: "p", name: "Web", teamKeys: ["ENG"])), ["Bug", "frontend"])
        XCTAssertEqual(LinearLabel.names(labels, for: nil), ["Bug", "bug-ops", "frontend"])
    }

    func testAMissingKeyFailsWithoutARequest() async {
        let (client, transport) = client(key: "  ", [])

        let projects = await client.projects()
        let labels = await client.labels()

        XCTAssertEqual(projects, .failure(.missingKey))
        XCTAssertEqual(labels, .failure(.missingKey))
        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertEqual(LinearFailure.missingKey.message, "LINEAR_API_KEY isn't set. Add it in Settings to list Linear projects.")
    }

    func testReportsEachKindOfFailure() async {
        let cases: [(response: (status: Int, body: String)?, failure: LinearFailure)] = [
            (nil, .unreachable),
            ((401, "{}"), .rejectedKey),
            ((400, #"{"errors":[{"message":"Authentication required","extensions":{"code":"AUTHENTICATION_ERROR"}}]}"#), .rejectedKey),
            ((429, "{}"), .rateLimited),
            ((400, #"{"errors":[{"message":"Rate limit exceeded","extensions":{"code":"RATELIMITED"}}]}"#), .rateLimited),
            ((200, #"{"data":null,"errors":[{"message":"Cannot query field \"bogus\""}]}"#), .graphQL(#"Cannot query field "bogus""#)),
            ((200, #"{"errors":[{}]}"#), .graphQL("unknown error")),
            ((502, "<html>Bad gateway</html>"), .httpStatus(502)),
            ((200, "not json"), .unreadable),
            ((200, #"{"data":{"projects":null}}"#), .unreadable),
        ]
        for (response, failure) in cases {
            let (client, _) = client(response.map { [$0] } ?? [])

            let result = await client.projects()

            XCTAssertEqual(result, .failure(failure), "\(String(describing: response))")
        }
        XCTAssertEqual(LinearFailure.httpStatus(502).message, "Linear answered with HTTP 502.")
        XCTAssertEqual(LinearFailure.graphQL("boom").message, "Linear reported an error: boom")
    }

    func testAFailureOnALaterPageFailsTheList() async {
        let first = #"{"data":{"issueLabels":{"nodes":[{"id":"l1","name":"a"}],"pageInfo":{"hasNextPage":true,"endCursor":"c1"}}}}"#
        let (client, _) = client([(200, first), (500, "{}")])

        let result = await client.labels()

        XCTAssertEqual(result, .failure(.httpStatus(500)))
    }
}
