import XCTest
@testable import SymphonyBarCore

/// Answers update requests from canned responses keyed by URL, and records every request.
final class StubUpdateTransport: UpdateTransport {
    var responses: [URL: (status: Int, body: String, headers: [String: String])] = [:]
    var requests: [URLRequest] = []

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard let url = request.url, let response = responses[url] else { throw URLError(.notConnectedToInternet) }
        let http = HTTPURLResponse(url: url, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: response.headers)!
        return (Data(response.body.utf8), http)
    }
}

final class UpdatesTests: XCTestCase {
    private let releaseURL = UpdateChecker.latestReleaseURL
    private let download = "https://github.com/tonypine/symphony/releases/download/v0.0.1.42"
    private var versionURL: URL { URL(string: "\(download)/version.json")! }
    private let notes = "12 changes since v0.0.1.41:\n\n- feat: something (abc1234)"

    private func releaseJSON(
        assets: [String] = ["Symphony-0.0.1.42.zip", "Symphony-0.0.1.42.zip.sha256", "version.json"],
        body: String? = nil
    ) throws -> String {
        let payload: [String: Any] = [
            "tag_name": "v0.0.1.42",
            "html_url": "https://github.com/tonypine/symphony/releases/tag/v0.0.1.42",
            "body": body ?? notes,
            "assets": assets.map { ["name": $0, "browser_download_url": "\(download)/\($0)"] },
        ]
        return String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
    }

    private let versionJSON = """
        {"version":"0.0.1.42","build":42,"sha256":"00","commit":"abc","published_at":"2026-10-02T12:00:00Z",
         "signed":false,"zip":"Symphony-0.0.1.42.zip","minisig":null,"changes":12}
        """

    private func stub(release: String? = nil, version: String? = nil, etag: String = #"W/"etag-1""#) throws -> StubUpdateTransport {
        let transport = StubUpdateTransport()
        transport.responses[releaseURL] = (200, try release ?? releaseJSON(), ["ETag": etag])
        transport.responses[versionURL] = (200, version ?? versionJSON, [:])
        return transport
    }

    private func release(changes: Int? = 12, signed: Bool = false) -> Release {
        Release(
            version: "0.0.1.42",
            build: 42,
            notes: notes,
            pageURL: URL(string: "https://github.com/tonypine/symphony/releases/tag/v0.0.1.42")!,
            changes: changes,
            assets: ReleaseAssets(
                zipName: "Symphony-0.0.1.42.zip",
                zip: URL(string: "\(download)/Symphony-0.0.1.42.zip")!,
                checksum: URL(string: "\(download)/Symphony-0.0.1.42.zip.sha256")!,
                signature: signed ? URL(string: "\(download)/Symphony-0.0.1.42.zip.minisig")! : nil
            )
        )
    }

    private let releaseBuild = AppBuild(build: 42, isDevelopment: false)

    func testNewerReleaseIsAvailable() async throws {
        let checker = UpdateChecker(transport: try stub())

        let result = await checker.check(current: AppBuild(build: 41, isDevelopment: false))

        XCTAssertEqual(result, .available(release()))
    }

    func testSameBuildIsUpToDate() async throws {
        let result = await UpdateChecker(transport: try stub()).check(current: releaseBuild)

        XCTAssertEqual(result, .upToDate(release()))
        XCTAssertEqual(UpdateMenu.manualResultLine(result), "Symphony is up to date (v0.0.1.42)")
    }

    func testOlderReleaseIsUpToDate() async throws {
        let result = await UpdateChecker(transport: try stub()).check(current: AppBuild(build: 50, isDevelopment: false))

        XCTAssertEqual(result, .upToDate(release()))
    }

    func testSignedReleaseListsItsSignature() async throws {
        let transport = try stub(
            release: releaseJSON(assets: [
                "Symphony-0.0.1.42.zip", "Symphony-0.0.1.42.zip.sha256", "Symphony-0.0.1.42.zip.minisig", "version.json",
            ]),
            version: versionJSON.replacingOccurrences(of: #""minisig":null"#, with: #""minisig":"Symphony-0.0.1.42.zip.minisig""#)
        )

        let result = await UpdateChecker(transport: transport).check(current: AppBuild(build: 41, isDevelopment: false))

        XCTAssertEqual(result, .available(release(signed: true)))
    }

    func testRequestIsUnauthenticatedGitHubJSON() throws {
        let request = UpdateChecker(transport: StubUpdateTransport()).releaseRequest()

        XCTAssertEqual(request.url?.absoluteString, "https://api.github.com/repos/tonypine/symphony/releases/latest")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "Symphony-macOS")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "If-None-Match"))
    }

    func testNotModifiedReusesTheCachedRelease() async throws {
        let transport = try stub()
        let checker = UpdateChecker(transport: transport)
        _ = await checker.check(current: AppBuild(build: 41, isDevelopment: false))

        transport.responses[releaseURL] = (304, "", [:])
        transport.requests = []
        let result = await checker.check(current: AppBuild(build: 41, isDevelopment: false))

        XCTAssertEqual(result, .available(release()))
        XCTAssertEqual(transport.requests.map(\.url), [releaseURL], "a 304 needs no version.json download")
        XCTAssertEqual(transport.requests.first?.value(forHTTPHeaderField: "If-None-Match"), #"W/"etag-1""#)
    }

    func testNotModifiedWithoutACachedReleaseFails() async {
        let transport = StubUpdateTransport()
        transport.responses[releaseURL] = (304, "", [:])

        let result = await UpdateChecker(transport: transport).check(current: releaseBuild)

        XCTAssertEqual(result, .failed("Couldn't check for updates: GitHub answered 304 Not Modified to a first request"))
    }

    func testIgnoredReleaseIsNotCached() async throws {
        let transport = try stub(release: releaseJSON(assets: ["version.json"]))
        let checker = UpdateChecker(transport: transport)
        _ = await checker.check(current: releaseBuild)

        XCTAssertNil(checker.releaseRequest().value(forHTTPHeaderField: "If-None-Match"))
    }

    func testMalformedReleaseJSON() async {
        let transport = StubUpdateTransport()
        transport.responses[releaseURL] = (200, "{\"tag_name\": 42", [:])

        let result = await UpdateChecker(transport: transport).check(current: releaseBuild)

        XCTAssertEqual(result, .failed("Couldn't check for updates: GitHub's latest release couldn't be read"))
    }

    func testMalformedVersionJSON() async throws {
        let result = await UpdateChecker(transport: try stub(version: #"{"version":"0.0.1.42","build":"x"}"#))
            .check(current: releaseBuild)

        XCTAssertEqual(result, .failed("Couldn't check for updates: version.json for v0.0.1.42 couldn't be read"))
    }

    func testVersionJSONHTTPErrorFails() async throws {
        let transport = try stub()
        transport.responses[versionURL] = (404, "Not Found", [:])

        let result = await UpdateChecker(transport: transport).check(current: releaseBuild)

        XCTAssertEqual(result, .failed("Couldn't check for updates: version.json for v0.0.1.42 couldn't be read"))
    }

    func testVersionJSONDownloadFailureFails() async throws {
        let transport = try stub()
        transport.responses[versionURL] = nil

        let result = await UpdateChecker(transport: transport).check(current: releaseBuild)

        XCTAssertEqual(result, .failed("Couldn't check for updates: couldn't download version.json for v0.0.1.42"))
    }

    func testReleaseWithoutVersionJSONIsIgnored() async throws {
        let transport = try stub(release: releaseJSON(assets: ["Symphony-0.0.1.42.zip", "Symphony-0.0.1.42.zip.sha256"]))

        let result = await UpdateChecker(transport: transport).check(current: AppBuild(build: 1, isDevelopment: false))

        XCTAssertEqual(result, .failed("Couldn't check for updates: the latest release (v0.0.1.42) has no version.json"))
    }

    func testReleaseWithoutTheZipOrChecksumIsIgnored() async throws {
        for assets in [["Symphony-0.0.1.42.zip.sha256", "version.json"], ["Symphony-0.0.1.42.zip", "version.json"]] {
            let transport = try stub(release: releaseJSON(assets: assets))

            let result = await UpdateChecker(transport: transport).check(current: AppBuild(build: 1, isDevelopment: false))

            XCTAssertEqual(result, .failed("Couldn't check for updates: the latest release (v0.0.1.42) has no app to download"))
        }
    }

    func testHTTPErrors() async {
        let cases: [(Int, String)] = [
            (403, "Couldn't check for updates: GitHub's rate limit is reached; try again later"),
            (429, "Couldn't check for updates: GitHub's rate limit is reached; try again later"),
            (404, "Couldn't check for updates: no Symphony release is published yet"),
            (500, "Couldn't check for updates: GitHub answered with HTTP 500"),
        ]
        for (status, message) in cases {
            let transport = StubUpdateTransport()
            transport.responses[releaseURL] = (status, "{}", [:])

            let result = await UpdateChecker(transport: transport).check(current: releaseBuild)

            XCTAssertEqual(result, .failed(message), "HTTP \(status)")
        }
    }

    func testUnreachableGitHub() async {
        let result = await UpdateChecker(transport: StubUpdateTransport()).check(current: releaseBuild)

        XCTAssertEqual(result, .failed("Couldn't check for updates: couldn't reach GitHub"))
        XCTAssertEqual(UpdateMenu.manualResultLine(result), "Couldn't check for updates: couldn't reach GitHub")
    }

    func testChangeCountFromNotes() {
        XCTAssertEqual(UpdateChecker.changeCount(notes: notes), 12)
        XCTAssertEqual(UpdateChecker.changeCount(notes: "1 change since v0.0.1.41:\n\n- fix"), 1)
        XCTAssertEqual(UpdateChecker.changeCount(notes: "3 changes:\n"), 3)
        XCTAssertNil(UpdateChecker.changeCount(notes: "Hand-written notes\n\n12 changes"))
        XCTAssertNil(UpdateChecker.changeCount(notes: "12 apples"))
        XCTAssertNil(UpdateChecker.changeCount(notes: ""))
    }

    func testChangeCountFallsBackToVersionJSON() async throws {
        let transport = try stub(release: releaseJSON(body: "Hand-written notes"))

        let result = await UpdateChecker(transport: transport).check(current: AppBuild(build: 41, isDevelopment: false))

        guard case let .available(release) = result else { return XCTFail("expected an update, got \(result)") }
        XCTAssertEqual(release.changes, 12)
        XCTAssertEqual(release.notes, "Hand-written notes")
    }

    func testAvailableTitles() {
        let current = AppBuild(build: 41, isDevelopment: false)

        XCTAssertEqual(UpdateMenu.availableTitle(release(), current: current), "Update available: v0.0.1.42 (12 changes)")
        XCTAssertEqual(UpdateMenu.availableTitle(release(changes: 1), current: current), "Update available: v0.0.1.42 (1 change)")
        XCTAssertEqual(UpdateMenu.availableTitle(release(changes: nil), current: current), "Update available: v0.0.1.42")
        XCTAssertEqual(
            UpdateMenu.availableTitle(release(), current: AppBuild(build: 1, isDevelopment: true)),
            "Update available: v0.0.1.42 (12 changes) · development build"
        )
        XCTAssertNil(UpdateMenu.manualResultLine(.available(release())))
        XCTAssertEqual(UpdateMenu.releaseNotesHeading(release()), "Symphony 0.0.1.42")
    }

    func testAppBuildFromInfoDictionary() {
        XCTAssertEqual(
            AppBuild(infoDictionary: ["CFBundleVersion": "42"], hasEmbeddedSymphony: true),
            AppBuild(build: 42, isDevelopment: false)
        )
        XCTAssertEqual(
            AppBuild(infoDictionary: ["CFBundleVersion": "1"], hasEmbeddedSymphony: false),
            AppBuild(build: 1, isDevelopment: true)
        )
        XCTAssertEqual(AppBuild(infoDictionary: ["CFBundleVersion": "1.2"], hasEmbeddedSymphony: true).build, 0)
        XCTAssertEqual(AppBuild(infoDictionary: nil, hasEmbeddedSymphony: false), AppBuild(build: 0, isDevelopment: true))
    }
}
