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
}

private final class RecordingWorkspace: FileLocationWorkspace {
    var browsed: [URL] = []
    var revealed: [URL] = []

    func openInBrowser(_ url: URL) { browsed.append(url) }
    func revealInFinder(_ url: URL) { revealed.append(url) }
}
