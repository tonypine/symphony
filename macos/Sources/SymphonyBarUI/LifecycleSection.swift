import AppKit
import SwiftUI
import SymphonyBarCore

// The catalog's Lifecycle section and Phase path component (`docs/design/director-ticket-page.md` §1 facts 7, 19 and
// 20): the five stages a ticket moves through, each with its state, visits and time, then one token bar against the
// ticket's cap split by the same stages (the Progress meter in its stacked form: `status.you` from 75 %,
// `status.problem` from 95 %); and the phases the ticket went through in order, with their counts and the times of
// their moves. The current stage's dot breathes while it works and the bar's segments resize on a spring; under
// Reduce Motion they are still.

// MARK: - The Lifecycle section

public struct LifecycleSection: View {
    let model: LifecycleModel

    /// The section's widest on a laptop's main column and on a desktop's (the catalog's Lifecycle).
    public static let laptopWidth: CGFloat = 780
    public static let desktopWidth: CGFloat = 1040

    public init(model: LifecycleModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
            Text("Lifecycle")
                .font(DesignTokens.TypeStyle.heading.font)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: DesignTokens.Space.s4) {
                LifecycleHead(model: model)
                StageStrip(stages: model.stages)
                TokenBarView(bar: model.tokens)
            }
            .padding(DesignTokens.Space.s4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DesignTokens.Surface.content.color, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous)
                    .strokeBorder(DesignTokens.Surface.separator.color)
            )
            .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Lifecycle")
        }
        .frame(maxWidth: Self.desktopWidth, alignment: .leading)
    }
}

/// Where the ticket is, and how long agents worked on it in all.
private struct LifecycleHead: View {
    let model: LifecycleModel

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.s2) {
            Group {
                if model.live {
                    LiveDot(size: 8)
                } else {
                    Circle().fill(DesignTokens.Status.idle.tint).frame(width: 8, height: 8)
                }
            }
            .frame(width: 12, height: 12)
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            .accessibilityHidden(true)
            Text(model.whereLine)
                .font(DesignTokens.TypeStyle.rowTitle.font)
                .lineLimit(2)
            Spacer(minLength: DesignTokens.Space.s3)
            Text(model.summary)
                .font(DesignTokens.TypeStyle.secondary.font)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
        }
        .accessibilityElement(children: .combine)
    }
}

/// The five stages left to right, sharing the width equally: a bar, the name with its visits, the state and time.
/// A stage's name never breaks: when the column is too narrow for every name on one line (a desktop's main column just
/// past the breakpoint, beside the rail and the decisions), the stages stack as rows, each name with its line beside it.
private struct StageStrip: View {
    let stages: [LifecycleModel.Stage]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: LifecycleSection.stageSpacing) {
                ForEach(Array(stages.enumerated()), id: \.element.id) { index, stage in
                    StageCell(stage: stage, corners: corners(index, stacked: false), stacked: false)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            // Its ideal width is what its names need whole, so ViewThatFits takes it only when they fit.
            .frame(minWidth: 0, idealWidth: LifecycleSection.stripWidth(titles: stages.map(\.title)), maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: LifecycleSection.stageSpacing) {
                ForEach(Array(stages.enumerated()), id: \.element.id) { index, stage in
                    StageCell(stage: stage, corners: corners(index, stacked: true), stacked: true)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Stages of the ticket")
    }

    private func corners(_ index: Int, stacked: Bool) -> RectangleCornerRadii {
        let outer = DesignTokens.Radius.row, inner = DesignTokens.Radius.mark
        let first = index == 0, last = index == stages.count - 1
        if stacked {
            return RectangleCornerRadii(
                topLeading: first ? outer : inner, bottomLeading: last ? outer : inner,
                bottomTrailing: last ? outer : inner, topTrailing: first ? outer : inner
            )
        }
        return RectangleCornerRadii(
            topLeading: first ? outer : inner, bottomLeading: first ? outer : inner,
            bottomTrailing: last ? outer : inner, topTrailing: last ? outer : inner
        )
    }
}

extension LifecycleSection {
    /// The gap between two stages.
    static let stageSpacing: CGFloat = 3
    /// A stage's name: 12 pt semibold.
    static let stageTitleSize: CGFloat = 12
    /// A stage's padding before and after its content.
    static let stageLeading: CGFloat = DesignTokens.Space.s2 + 2
    static let stageTrailing: CGFloat = DesignTokens.Space.s2
    /// The stage's symbol and the gap after it, before the name.
    static let stageSymbolWidth: CGFloat = 14
    static let stageSymbolGap: CGFloat = 5

    /// The width the stages need side by side with every name whole on one line: as many equal cells as `titles`,
    /// each as wide as the widest name with its symbol and padding.
    public static func stripWidth(titles: [String]) -> CGFloat {
        guard !titles.isEmpty else { return 0 }
        let font = NSFont.systemFont(ofSize: stageTitleSize, weight: .semibold)
        let widest = titles.map { ceil(($0 as NSString).size(withAttributes: [.font: font]).width) }.max() ?? 0
        let cell = stageLeading + stageSymbolWidth + stageSymbolGap + widest + stageTrailing
        return cell * CGFloat(titles.count) + stageSpacing * CGFloat(titles.count - 1)
    }
}

private struct StageCell: View {
    let stage: LifecycleModel.Stage
    let corners: RectangleCornerRadii
    /// One row of a stacked strip: the name and the line side by side under the bar.
    let stacked: Bool

    private var current: Bool { stage.state == .current }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s1 + 2) {
            StageBar(state: stage.state, status: stage.status)
            if stacked {
                HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.s3) {
                    name
                    Spacer(minLength: 0)
                    line.multilineTextAlignment(.trailing)
                }
            } else {
                name
                line
            }
        }
        .padding(EdgeInsets(top: DesignTokens.Space.s2, leading: LifecycleSection.stageLeading, bottom: DesignTokens.Space.s2, trailing: LifecycleSection.stageTrailing))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            UnevenRoundedRectangle(cornerRadii: corners, style: .continuous)
                .fill(current ? stage.status.tint.opacity(0.12) : DesignTokens.Surface.raised.color.opacity(0.6))
        )
        .overlay(
            UnevenRoundedRectangle(cornerRadii: corners, style: .continuous)
                .strokeBorder(current ? stage.status.tint.opacity(0.3) : .clear)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(stage.accessibilityLabel)
    }

    /// The symbol and the name with its visits, always on one line.
    private var name: some View {
        HStack(alignment: .firstTextBaseline, spacing: LifecycleSection.stageSymbolGap) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(stage.state == .notYet || stage.state == .skipped ? AnyShapeStyle(.tertiary) : AnyShapeStyle(stage.status.tint))
                .accessibilityHidden(true)
            Text(stage.title)
                .font(.system(size: LifecycleSection.stageTitleSize, weight: .semibold))
                .foregroundStyle(stage.state == .skipped ? AnyShapeStyle(.tertiary) : stage.state == .notYet ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .lineLimit(1)
                .fixedSize()
        }
    }

    /// The state and time.
    private var line: some View {
        Text(stage.line)
            .font(DesignTokens.TypeStyle.caption.font)
            .fontWeight(current ? .semibold : .regular)
            .foregroundStyle(current ? AnyShapeStyle(stage.status.tint) : AnyShapeStyle(.secondary))
            .monospacedDigit()
            .fixedSize(horizontal: false, vertical: true)
    }

    private var symbol: String {
        switch stage.state {
        case .current: "circle.dotted.circle"
        case .passed: "checkmark.circle.fill"
        case .skipped: "chevron.right"
        case .notYet: "clock"
        }
    }
}

/// A stage's bar: full in the done colour once passed, partly filled while current, dashed when skipped, empty ahead.
private struct StageBar: View {
    let state: TicketLifecycle.StageState
    let status: DesignTokens.Status

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                if state == .skipped {
                    Capsule().strokeBorder(.tertiary, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                } else {
                    Capsule().fill(DesignTokens.Surface.raised.color)
                }
                switch state {
                case .passed: Capsule().fill(status.tint)
                case .current: Capsule().fill(status.tint).frame(width: proxy.size.width * 0.55)
                case .skipped, .notYet: EmptyView()
                }
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}

/// One bar for the ticket's tokens: the stages fill its cap from the left in their landing order, the rest stays
/// empty, a legend carries the numbers and a note says what the cap means now.
struct TokenBarView: View {
    let bar: LifecycleModel.TokenBar
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var levelTint: Color? {
        guard bar.cap != nil else { return nil }
        return switch bar.level {
        case .normal: nil
        case .near: DesignTokens.Status.you.tint
        case .atLimit: DesignTokens.Status.problem.tint
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
            HStack(alignment: .firstTextBaseline) {
                Text("Tokens")
                    .font(DesignTokens.TypeStyle.secondary.font)
                    .foregroundStyle(.secondary)
                Spacer(minLength: DesignTokens.Space.s3)
                Text(bar.value)
                    .font(DesignTokens.TypeStyle.secondary.font)
                    .foregroundStyle(levelTint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.primary))
                    .fontWeight(levelTint == nil ? .regular : .semibold)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            track
            legend
            if let note = bar.note {
                Text(note)
                    .font(DesignTokens.TypeStyle.secondary.font)
                    .foregroundStyle(levelTint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(bar.accessibilityLabel)
    }

    private var track: some View {
        GeometryReader { proxy in
            let filled = bar.segments.filter { $0.tokens > 0 }
            let scale = Double(max(bar.scale, 1))
            let gaps = CGFloat(max(filled.count - (bar.total < bar.scale ? 0 : 1), 0)) * 3
            let width = max(proxy.size.width - gaps, 0)
            HStack(spacing: 3) {
                ForEach(filled) { segment in
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(segment.series.color)
                        .frame(width: max(width * Double(segment.tokens) / scale, 3))
                }
                if bar.total < bar.scale || filled.isEmpty {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(DesignTokens.Surface.raised.color)
                        .overlay(
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .strokeBorder(levelTint?.opacity(0.6) ?? DesignTokens.Surface.separator.color)
                        )
                }
            }
            .clipShape(Capsule())
            .animation(.motion(.fold, reduceMotion: reduceMotion), value: bar)
        }
        .frame(height: 12)
    }

    private var legend: some View {
        HStack(spacing: DesignTokens.Space.s4) {
            ForEach(bar.segments) { segment in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(segment.series.color)
                        .frame(width: 8, height: 8)
                    Text(segment.name)
                        .foregroundStyle(.secondary)
                    Text(segment.value)
                        .foregroundStyle(.primary)
                        .monospacedDigit()
                }
                .font(DesignTokens.TypeStyle.secondary.font)
                .fixedSize()
            }
        }
    }
}

// MARK: - The Phase path

/// The phases a ticket went through, in the order it first entered each: its name with ×n when it entered more than
/// once, how long it spent there and when each move into it happened; the phase it is in now carries its status tint.
/// `compact` keeps the names and counts only, for a board row's preview.
public struct PhasePath: View {
    let model: PhasePathModel
    let compact: Bool

    public init(model: PhasePathModel, compact: Bool = false) {
        self.model = model
        self.compact = compact
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: compact ? DesignTokens.Space.s1 : DesignTokens.Space.s2) {
            FlowLayout(spacing: compact ? 4 : 6, lineSpacing: compact ? 4 : 6) {
                ForEach(Array(model.phases.enumerated()), id: \.element.id) { index, phase in
                    HStack(spacing: compact ? 4 : 6) {
                        if index > 0 {
                            Image(systemName: "chevron.right")
                                .font(.system(size: compact ? 8 : 9, weight: .semibold))
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                        }
                        PhaseChip(phase: phase, compact: compact)
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(model.accessibilityLabel)
            Text(model.summary)
                .font(compact ? DesignTokens.TypeStyle.caption.font : DesignTokens.TypeStyle.secondary.font)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}

private struct PhaseChip: View {
    let phase: PhasePathModel.Phase
    let compact: Bool

    private var current: Bool { phase.state == .current }

    private var cornerRadius: CGFloat { compact ? 6 : DesignTokens.Radius.row - 2 }
    private var nameFont: Font { .system(size: compact ? 11 : 12, weight: current ? .semibold : .medium) }
    private var nameStyle: AnyShapeStyle { current ? AnyShapeStyle(phase.status.tint) : AnyShapeStyle(.primary) }
    private var chipFill: Color { current ? phase.status.tint.opacity(0.14) : DesignTokens.Surface.raised.color }
    private var chipStroke: Color { current ? phase.status.tint.opacity(0.45) : .clear }
    private var horizontalPadding: CGFloat { compact ? 6 : DesignTokens.Space.s2 }
    private var verticalPadding: CGFloat { compact ? 2 : DesignTokens.Space.s1 + 1 }
    private var helpText: String { phase.entered.isEmpty ? "" : "Entered " + phase.entered.joined(separator: ", ") }

    private var titleRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(phase.name)
                .font(nameFont)
                .foregroundStyle(nameStyle)
            if let count = phase.countLabel {
                Text(count)
                    .font(.system(size: compact ? 10 : 11, weight: .semibold))
                    .foregroundStyle(DesignTokens.Status.you.tint)
                    .monospacedDigit()
            }
        }
        .lineLimit(1)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 1) {
            titleRow
            if !compact, let meta = meta {
                Text(meta)
                    .font(DesignTokens.TypeStyle.caption.font)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
        }
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return content
            .fixedSize()
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background(shape.fill(chipFill))
            .overlay(shape.strokeBorder(chipStroke))
            .help(helpText)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(phase.accessibilityLabel)
    }

    /// "16:02 · 29 min": when it was last entered and how long it spent there in all.
    private var meta: String? {
        let parts = [phase.entered.last, phase.time].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Lays its children out left to right, wrapping onto a new line when the next one doesn't fit.
struct FlowLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let next = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if !row.indices.isEmpty, next > width {
                rows.append(row)
                row = Row()
            }
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}

/// The Lifecycle card draws again only when its model changed (TP-1480).
extension LifecycleSection: Equatable {
    nonisolated public static func == (lhs: LifecycleSection, rhs: LifecycleSection) -> Bool { lhs.model == rhs.model }
}
