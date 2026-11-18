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

    /// What acts keeps its whole width (a title is never cut to "Force a Ti…"); what narrows takes the rest before the
    /// gap between the sides does, its controls wrapping onto the next line when they don't fit on one, so no page's
    /// bar is wider than the page (Audit beside its inspector) and a control that wraps itself (Insights' groups) wraps
    /// within the line.
    private var controls: some View {
        HStack(spacing: DesignTokens.ControlBar.gap) {
            ControlBarFlow(spacing: DesignTokens.ControlBar.gap) { narrow }
                .layoutPriority(1)
            Spacer(minLength: DesignTokens.ControlBar.sidesGap)
            act
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)
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
        let width = proposal.width ?? subviews[0].sizeThatFits(.unspecified).width
        let place = Self.arrange(width: width, subviews: subviews)
        return CGSize(width: width, height: place.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let place = Self.arrange(width: bounds.width, subviews: subviews)
        if place.beside {
            subviews[0].place(
                at: CGPoint(x: bounds.minX, y: bounds.minY + (place.height - place.controls.height) / 2),
                proposal: ProposedViewSize(width: bounds.width - place.summary.width - DesignTokens.ControlBar.groupGap, height: place.controls.height)
            )
            subviews[1].place(
                at: CGPoint(x: bounds.maxX, y: bounds.minY + place.height / 2), anchor: .trailing, proposal: ProposedViewSize(place.summary)
            )
        } else {
            subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.minY), proposal: ProposedViewSize(width: bounds.width, height: place.controls.height))
            subviews[1].place(
                at: CGPoint(x: bounds.minX, y: bounds.minY + place.controls.height + DesignTokens.ControlBar.summaryGap),
                proposal: ProposedViewSize(width: bounds.width, height: place.summary.height)
            )
        }
    }

    /// The controls on one line beside the summary when the bar holds both, else the controls in the bar's width
    /// (wrapped when they don't fit on one line) over the summary.
    private static func arrange(width: CGFloat, subviews: Subviews) -> (beside: Bool, controls: CGSize, summary: CGSize, height: CGFloat) {
        let line = subviews[0].sizeThatFits(.unspecified)
        let summary = subviews[1].sizeThatFits(ProposedViewSize(width: width, height: nil))
        if beside(width: width, controls: line, summary: summary) {
            return (true, line, summary, max(line.height, summary.height))
        }
        let controls = subviews[0].sizeThatFits(ProposedViewSize(width: width, height: nil))
        return (false, controls, summary, controls.height + DesignTokens.ControlBar.summaryGap + summary.height)
    }

    /// Whether the summary sits beside controls `controls` big in a bar `width` wide.
    static func beside(width: CGFloat, controls: CGSize, summary: CGSize) -> Bool {
        DesignTokens.ControlBar.summaryBeside(width: width) && controls.width + DesignTokens.ControlBar.groupGap + summary.width <= width
    }
}

/// What narrows the page, left to right, each control on the line while it fits and the next ones on the line under
/// it; the controls of a line centred on it. A control wider than the bar on its own (a group that wraps itself) is
/// offered the bar's width.
struct ControlBarFlow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        Self.arrange(width: proposal.width, sizes: Self.sizes(width: proposal.width, subviews: subviews), spacing: spacing).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = Self.sizes(width: bounds.width, subviews: subviews)
        let frames = Self.arrange(width: bounds.width, sizes: sizes, spacing: spacing).frames
        for (subview, frame) in zip(subviews, frames) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }

    /// Each control's size: its own, or in `width` when its own is wider.
    private static func sizes(width: CGFloat?, subviews: Subviews) -> [CGSize] {
        subviews.map { subview in
            let size = subview.sizeThatFits(.unspecified)
            guard let width, size.width > width else { return size }
            return subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
        }
    }

    /// Where controls `sizes` big go in a bar `width` wide (one line when nil), and the size they take.
    static func arrange(width: CGFloat?, sizes: [CGSize], spacing: CGFloat) -> (frames: [CGRect], size: CGSize) {
        let maxWidth = width ?? .infinity
        var lines: [[Int]] = [[]]
        var x: CGFloat = 0
        for (index, size) in sizes.enumerated() {
            if !lines[lines.count - 1].isEmpty, x + spacing + size.width > maxWidth {
                lines.append([])
            }
            x = lines[lines.count - 1].isEmpty ? size.width : x + spacing + size.width
            lines[lines.count - 1].append(index)
        }
        var frames = [CGRect](repeating: .zero, count: sizes.count)
        var y: CGFloat = 0
        var widest: CGFloat = 0
        for line in lines where !line.isEmpty {
            let height = line.map { sizes[$0].height }.max() ?? 0
            var x: CGFloat = 0
            for index in line {
                frames[index] = CGRect(origin: CGPoint(x: x, y: y + (height - sizes[index].height) / 2), size: sizes[index])
                x += sizes[index].width + spacing
            }
            widest = max(widest, x - spacing)
            y += height + spacing
        }
        return (frames, CGSize(width: widest, height: max(y - spacing, 0)))
    }
}
