import XCTest
@testable import SymphonyBarCore

final class LinearLinkTests: XCTestCase {
    private let issue = URL(string: "https://linear.app/tonypine/issue/TP-938/open-in-linear")!

    func testAnIssueLinkOpensInTheDesktopAppWithTheSamePath() {
        XCTAssertEqual(
            LinearLink.desktopURL(for: issue),
            URL(string: "linear://tonypine/issue/TP-938/open-in-linear")
        )
    }

    func testTheCommentFragmentAndQueryAreKept() {
        let comment = URL(string: "https://linear.app/acme/issue/BIL-206?noRedirect=1#comment-5d1e0a2c")!

        XCTAssertEqual(
            LinearLink.desktopURL(for: comment),
            URL(string: "linear://acme/issue/BIL-206?noRedirect=1#comment-5d1e0a2c")
        )
    }

    func testAnHTTPOrMixedCaseLinkIsStillALinearLink() {
        XCTAssertEqual(
            LinearLink.desktopURL(for: URL(string: "http://Linear.App/acme/project/launch")!),
            URL(string: "linear://acme/project/launch")
        )
    }

    func testOtherLinksHaveNoDesktopLink() {
        for link in [
            "https://github.com/acme/api/pull/7",
            "https://api.linear.app/graphql",
            "https://uploads.linear.app/a/b/c",
            "https://linear.app.example.com/acme/issue/X-1",
            "linear://acme/issue/X-1",
            "file:///Users/me/symphony.log",
        ] {
            XCTAssertNil(LinearLink.desktopURL(for: URL(string: link)!), link)
        }
    }

    func testTheDesktopLinkOpensWhenAnAppHandlesIt() {
        var asked: URL?
        let target = LinearLink.target(for: issue) { url in
            asked = url
            return true
        }

        XCTAssertEqual(target, URL(string: "linear://tonypine/issue/TP-938/open-in-linear"))
        XCTAssertEqual(asked, target)
    }

    func testTheWebLinkOpensWhenNoAppHandlesTheDesktopLink() {
        XCTAssertEqual(LinearLink.target(for: issue) { _ in false }, issue)
    }

    func testAnotherLinkOpensAsItIsWithoutAskingForAnApp() {
        let pullRequest = URL(string: "https://github.com/acme/api/pull/7")!
        var asked = false

        XCTAssertEqual(
            LinearLink.target(for: pullRequest) { _ in
                asked = true
                return true
            },
            pullRequest
        )
        XCTAssertFalse(asked)
    }
}
