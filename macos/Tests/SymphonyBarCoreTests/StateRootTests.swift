import XCTest
@testable import SymphonyBarCore

final class StateRootTests: XCTestCase {
    private var home: URL!
    private var base: URL { StateRoot.defaultDirectory(home: home) }
    private var release: URL { base.appendingPathComponent("release", isDirectory: true) }

    override func setUpWithError() throws {
        home = uniqueTemporaryDirectory("state-root")
        try FileManager.default.createDirectory(at: release, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func write(_ contents: String, to name: String, in root: URL, modified: Date = Date()) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent(name)
        try contents.write(to: file, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
    }

    func testDefaultDirectory() {
        XCTAssertEqual(
            StateRoot.defaultDirectory(home: URL(fileURLWithPath: "/Users/me")).path,
            "/Users/me/Library/Application Support/symphony"
        )
    }

    func testUsesTheDefaultDirectoryWhenNothingWasWritten() {
        XCTAssertEqual(StateRoot.locate(environment: [:], home: home), base)
    }

    func testSymphonyStateRootWins() throws {
        try write("http://127.0.0.1:4001\n", to: "control_url", in: release)

        XCTAssertEqual(
            StateRoot.locate(environment: ["SYMPHONY_STATE_ROOT": " /srv/symphony/state \n"], home: home).path,
            "/srv/symphony/state"
        )
        XCTAssertEqual(
            StateRoot.locate(environment: ["SYMPHONY_STATE_ROOT": "~/state"], home: home).path,
            (NSHomeDirectory() as NSString).appendingPathComponent("state")
        )
        // Blank counts as not set, as in SymphonyElixir.Paths.
        XCTAssertEqual(StateRoot.locate(environment: ["SYMPHONY_STATE_ROOT": "  "], home: home), release)
    }

    func testPicksTheReleaseSubdirectoryWhenItsControlURLIsNewer() throws {
        try write("http://127.0.0.1:4000\n", to: "control_url", in: base, modified: Date(timeIntervalSinceNow: -60))
        try write("http://127.0.0.1:4001\n", to: "control_url", in: release)

        let root = StateRoot.locate(environment: [:], home: home)
        XCTAssertEqual(root, release)
        XCTAssertEqual(StateRoot.controlURL(in: root)?.absoluteString, "http://127.0.0.1:4001")
    }

    func testPicksTheDefaultDirectoryWhenItsControlURLIsNewer() throws {
        try write("http://127.0.0.1:4001\n", to: "control_url", in: release, modified: Date(timeIntervalSinceNow: -60))
        try write("http://127.0.0.1:4000\n", to: "control_url", in: base)

        XCTAssertEqual(StateRoot.locate(environment: [:], home: home), base)
    }

    func testFallsBackToTheDirectoryHoldingAControlToken() throws {
        try write("abc\n", to: "control_token", in: release)

        XCTAssertEqual(StateRoot.locate(environment: [:], home: home), release)
    }

    func testControlURLDefaultsWhenTheFileIsMissing() {
        XCTAssertEqual(StateRoot.controlURL(in: base), SymphonyState.defaultBaseURL)
    }

    func testControlURLUsesTheGivenFallback() throws {
        let fallback = URL(string: "http://127.0.0.1:4999")!
        XCTAssertNil(StateRoot.controlURL(in: base, fallback: nil))
        XCTAssertEqual(StateRoot.controlURL(in: base, fallback: fallback), fallback)

        try write("not a url\n", to: "control_url", in: base)
        XCTAssertNil(StateRoot.controlURL(in: base, fallback: nil))

        try write("http://127.0.0.1:4000\n", to: "control_url", in: base)
        XCTAssertEqual(StateRoot.controlURL(in: base, fallback: nil)?.absoluteString, "http://127.0.0.1:4000")
    }

    func testReadsTheControlToken() throws {
        XCTAssertNil(StateRoot.controlToken(in: base))
        try write("0123abcd\n", to: "control_token", in: base)

        XCTAssertEqual(StateRoot.controlToken(in: base), "0123abcd")
        XCTAssertEqual(StateRoot.controlTokenFile(in: base), base.appendingPathComponent("control_token"))
    }

    func testReadsAnOwnerOnlyControlToken() throws {
        // Symphony writes the token with mode 0600; the app runs as the same user.
        try write("0123abcd\n", to: "control_token", in: base)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: StateRoot.controlTokenFile(in: base).path)

        XCTAssertEqual(StateRoot.controlToken(in: base), "0123abcd")
    }

    func testTokenContents() {
        XCTAssertEqual(StateRoot.token(contents: " abc \n"), "abc")
        XCTAssertNil(StateRoot.token(contents: "\n"))
        XCTAssertNil(StateRoot.token(contents: nil))
    }
}
