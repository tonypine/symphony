import Foundation
import SymphonyBarCore
import XCTest

/// A question's file location (TP-1386): found in its text, opened in the browser or shown in Finder.
final class FileLocationsTests: XCTestCase {
    private let catalog = "/Users/me/symphony-workspaces/symphony/TP-1382/index.html"

    func testItFindsAnAbsolutePathAndAFileLinkWithoutTheSentencesPunctuation() {
        let text = "The catalog is at \(catalog). Or open (file://\(catalog)), or file://localhost/tmp/a%20b.png!"
        let locations = FileLocations.find(in: text)
        let string = text as NSString
        XCTAssertEqual(locations.map { string.substring(with: $0.range) }, [catalog, "file://\(catalog)", "file://localhost/tmp/a%20b.png"])
        XCTAssertEqual(locations.map(\.url.path), [catalog, catalog, "/tmp/a b.png"])
        XCTAssertTrue(locations.allSatisfy(\.url.isFileURL))
    }

    func testWordsWithASlashAreNoLocation() {
        let text = "and/or, TP-1382/index.html, ~/notes, lib/foo.ex, //server/share, https://example.com/a.html, a / b, file://server/x"
        XCTAssertEqual(FileLocations.find(in: text), [])
    }

    func testAnHTMLFileOpensInTheBrowserAndAnythingElseIsShownInFinder() {
        let workspace = RecordingWorkspace()
        let locations = FileLocations.find(in: "Open file://\(catalog), /tmp/Prototype.HTM, /tmp/shot.png and /tmp/folder.")
        XCTAssertEqual(locations.map(\.opening), [.browser, .browser, .finder, .finder])
        locations.forEach { $0.open(in: workspace) }
        XCTAssertEqual(workspace.browsed.map(\.path), [catalog, "/tmp/Prototype.HTM"])
        XCTAssertEqual(workspace.revealed.map(\.path), ["/tmp/shot.png", "/tmp/folder"])
    }

    /// The `inbox-file-location` fixture QA walks: TP-892's decision holds a workspace HTML page in its why, which the
    /// Inbox and the ticket page's "Your decision" card show, and a `file://` link to a screenshot in an option.
    func testTheFileLocationFixtureHoldsAPageForTheBrowserAndAFileForFinder() throws {
        let folder = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/director-app/inbox-file-location/api/v1", isDirectory: true)
        let items = try XCTUnwrap(InboxPayload.decode(Data(contentsOf: folder.appendingPathComponent("inbox.json")))?.items)
        let workspace = "/Users/director/symphony-workspaces/symphony/TP-892"
        let issue = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("TP-892.json"))) as? [String: Any])
        XCTAssertEqual((issue["workspace"] as? [String: Any])?["path"] as? String, workspace)

        let brief = try XCTUnwrap(TicketPage.Brief(identifier: "TP-892", items: items))
        XCTAssertEqual(brief.title, "Your decision")
        let page = brief.paragraphs.flatMap { FileLocations.find(in: $0) }
        XCTAssertEqual(page.map(\.url.path), ["\(workspace)/design/index.html"])
        XCTAssertEqual(page.map(\.opening), [.browser])

        let options = try XCTUnwrap(items.first { $0.identifier == "TP-892" }?.review.action?.options)
        let effects = options.flatMap { FileLocations.find(in: $0.effect ?? "") }
        XCTAssertEqual(effects.map(\.url.path), ["\(workspace)/design/final-verification.png"])
        XCTAssertEqual(effects.map(\.opening), [.finder])
    }
}

private final class RecordingWorkspace: FileLocationWorkspace {
    var browsed: [URL] = []
    var revealed: [URL] = []

    func openInBrowser(_ url: URL) { browsed.append(url) }
    func revealInFinder(_ url: URL) { revealed.append(url) }
}
