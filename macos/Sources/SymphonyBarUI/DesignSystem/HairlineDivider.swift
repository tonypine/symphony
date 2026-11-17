import SwiftUI
import SymphonyBarCore

/// The design's hairline divider (TP-1485): a 1 pt line in the catalog's separator colour (`--stroke-separator`),
/// vertical or horizontal. A vertical one has the length its caller sets (the identifier line's `.ident-sep` is 14 pt,
/// the moves row's `.rail-sep` 20 pt); a horizontal one runs as wide as it is offered unless a length is set. It
/// draws nothing VoiceOver reads. Named apart from SwiftUI's own `Divider`, which stays where it is used for now.
public struct HairlineDivider: View {
    public enum Axis: Equatable {
        case vertical
        case horizontal
    }

    /// The line's thickness, the catalog's 1 px.
    public static let thickness: CGFloat = 1

    let axis: Axis
    let length: CGFloat?

    public init(_ axis: Axis = .horizontal, length: CGFloat? = nil) {
        self.axis = axis
        self.length = length
    }

    public var body: some View {
        Rectangle()
            .fill(DesignTokens.ColorToken.strokeSeparator.color)
            .frame(width: axis == .vertical ? Self.thickness : length, height: axis == .vertical ? length : Self.thickness)
            .accessibilityHidden(true)
    }
}
