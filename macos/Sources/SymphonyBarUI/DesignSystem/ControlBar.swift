import SwiftUI
import SymphonyBarCore

// The catalog's Control bar (`sections/control-bar`, `.control-bar`; the Tickets page's `.tk-bar`; TP-1497): the one
// bar a page holds its own controls in. Every page's bar is this one; no page draws a bar of its own making.

/// The catalog's Control bar: glass at the top of a page, what narrows the page (the scope, the search, the filters) at
/// the left and what acts on it (Export…, Force a Ticket…, Check Again) at the right, its controls small (24 pt). With
/// a `summary`, the one line of what the page shows: on its own line under the controls on a laptop, right aligned
/// beside them from `DesignTokens.ControlBar.summaryBesideWidth` (a desktop) when the line holds both.
public struct ControlBar<Narrow: View, Act: View>: View {
    let label: String
    let summary: String?
    let narrow: Narrow
    let act: Act
    @Environment(\.offscreenSnapshot) private var offscreenSnapshot
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// `label` is what VoiceOver calls the bar ("What the page shows").
    public init(_ label: String, summary: String? = nil, @ViewBuilder narrow: () -> Narrow, @ViewBuilder act: () -> Act) {
        self.label = label
        self.summary = summary
        self.narrow = narrow()
        self.act = act()
    }

    public var body: some View {
        let bar = DesignTokens.ControlBar.self
        let shape = RoundedRectangle(cornerRadius: bar.radius, style: .continuous)
        Group {
            if let summary {
                ControlBarLayout {
                    controls
                    summaryLine(summary)
                }
            } else {
                controls
            }
        }
        .padding(.horizontal, bar.horizontalPadding)
        .padding(.vertical, bar.verticalPadding)
        .background {
            // An offscreen snapshot has no window behind it to blur, and Reduce Transparency wants none: either draws
            // the glass's solid surface.
            if offscreenSnapshot || reduceTransparency {
                shape.fill(bar.glass.solid.color)
            } else {
                Color.clear.glassBackground(bar.glass, in: shape)
            }
        }
        .edgeHighlight(shape)
        .elevation(bar.elevation, in: shape)
        .padding(.horizontal, bar.pageInset)
        .padding(.vertical, bar.pageGap)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }

    private var controls: some View {
        HStack(spacing: DesignTokens.ControlBar.gap) {
            narrow
            Spacer(minLength: DesignTokens.ControlBar.sidesGap)
            act
        }
    }

    private func summaryLine(_ summary: String) -> some View {
        Text(summary)
            .textStyle(.secondary)
            .foregroundStyle(DesignTokens.TextColor.secondary.color)
            .monospacedDigit()
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, DesignTokens.ControlBar.summaryInset)
            .accessibilityLabel("Showing \(summary)")
    }
}

extension ControlBar where Act == EmptyView {
    /// A bar whose controls all narrow the page.
    public init(_ label: String, summary: String? = nil, @ViewBuilder narrow: () -> Narrow) {
        self.init(label, summary: summary, narrow: narrow) { EmptyView() }
    }
}

/// The bar's two parts: the controls, then the summary on its own line under them, or right aligned on their line once
/// the bar is wide enough and the line holds both.
struct ControlBarLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let controls = subviews[0].sizeThatFits(.unspecified)
        let width = proposal.width ?? controls.width
        let summary = subviews[1].sizeThatFits(ProposedViewSize(width: width, height: nil))
        if Self.beside(width: width, controls: controls, summary: summary) {
            return CGSize(width: width, height: max(controls.height, summary.height))
        }
        return CGSize(width: width, height: controls.height + DesignTokens.ControlBar.summaryGap + summary.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let controls = subviews[0].sizeThatFits(.unspecified)
        let summary = subviews[1].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
        if Self.beside(width: bounds.width, controls: controls, summary: summary) {
            let height = max(controls.height, summary.height)
            subviews[0].place(
                at: CGPoint(x: bounds.minX, y: bounds.minY + (height - controls.height) / 2),
                proposal: ProposedViewSize(width: bounds.width - summary.width - DesignTokens.ControlBar.groupGap, height: controls.height)
            )
            subviews[1].place(
                at: CGPoint(x: bounds.maxX, y: bounds.minY + height / 2), anchor: .trailing, proposal: ProposedViewSize(summary)
            )
        } else {
            subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.minY), proposal: ProposedViewSize(width: bounds.width, height: controls.height))
            subviews[1].place(
                at: CGPoint(x: bounds.minX, y: bounds.minY + controls.height + DesignTokens.ControlBar.summaryGap),
                proposal: ProposedViewSize(width: bounds.width, height: summary.height)
            )
        }
    }

    /// Whether the summary sits beside controls `controls` big in a bar `width` wide.
    static func beside(width: CGFloat, controls: CGSize, summary: CGSize) -> Bool {
        DesignTokens.ControlBar.summaryBeside(width: width) && controls.width + DesignTokens.ControlBar.groupGap + summary.width <= width
    }
}
