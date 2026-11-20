import CoreGraphics

/// How a set of thumbnails fits the width it is given: they wrap onto further rows, at most `maxRows` of them. When the
/// set does not fit, the last cell of the last row is a tile that says how many are not shown, so `shown` thumbnails
/// and that tile fill the rows.
public struct ThumbnailRowPlan: Equatable {
    public static let defaultMaxRows = 2

    /// How many thumbnails sit side by side in a row (at least one).
    public let columns: Int
    /// How many thumbnails are drawn.
    public let shown: Int
    /// How many are not drawn: the tile's number; 0 when they all fit and there is no tile.
    public let hidden: Int

    public var hasMoreTile: Bool { hidden > 0 }

    /// The plan for `count` thumbnails of `thumbnailWidth` with `spacing` between them in `width`.
    public init(count: Int, width: CGFloat, thumbnailWidth: CGFloat, spacing: CGFloat, maxRows: Int = ThumbnailRowPlan.defaultMaxRows) {
        let fitting = thumbnailWidth > 0 ? Int(((width + spacing) / (thumbnailWidth + spacing)).rounded(.down)) : 1
        columns = max(1, fitting)
        let capacity = columns * max(1, maxRows)
        let total = max(0, count)
        if total <= capacity {
            shown = total
            hidden = 0
        } else {
            shown = capacity - 1
            hidden = total - shown
        }
    }

    /// A tile always stands for at least two: it takes the place of one thumbnail and the one that did not fit.
    public static func moreAccessibilityLabel(_ hidden: Int) -> String { "\(hidden) more screenshots" }

    public static func moreText(_ hidden: Int) -> String { "+\(hidden)" }
}
