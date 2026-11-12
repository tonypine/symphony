import AppKit
import SymphonyBarCore
import XCTest

/// The toolbar's line under the title is cut at the end past the title's width (design system: at most 260 pt), so
/// every view's own subtitle fits it whole (TP-1489: the Journal's was cut off).
final class ToolbarSubtitleTests: XCTestCase {
    func testEveryViewsSubtitleFitsTheToolbarTitleWidthInTheSubheadlineFont() {
        let font = NSFont.preferredFont(forTextStyle: .subheadline)
        for view in SymphonyView.allCases {
            let width = (view.subtitle as NSString).size(withAttributes: [.font: font]).width
            XCTAssertLessThanOrEqual(
                width, DesignTokens.Layout.toolbarTitleMaxWidth,
                "\(view.title)'s subtitle \"\(view.subtitle)\" is \(Int(width)) pt wide"
            )
        }
    }
}
