import SwiftUI
import SymphonyBarCore

/// What the Overview's buttons do.
struct OverviewActions {
    var resume: () -> Void
    var perform: (Overview.Fix) -> Void
    /// The control request under way; its button is off until it is answered.
    var controlInFlight: ControlAction?
}

/// The Overview in a scroll view, laid out for the width it gets.
struct OverviewView: View {
    let overview: Overview
    let actions: OverviewActions
    @State private var width: CGFloat = DesignTokens.Layout.windowWidth - DesignTokens.Layout.sidebarWidth

    var body: some View {
        ScrollView {
            OverviewBody(overview: overview, actions: actions, width: width)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}

/// The Overview's sections, outside the scroll view so they also render offscreen. Sections with nothing to say
/// aren't drawn.
struct OverviewBody: View {
    let overview: Overview
    let actions: OverviewActions
    /// The width available: the side column goes beside the main column when both fit, under it otherwise.
    let width: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let sideColumnWidth: CGFloat = 300
    static let mainColumnMinWidth: CGFloat = 480

    private var sideBySide: Bool {
        width - 2 * DesignTokens.Space.s5 >= Self.mainColumnMinWidth + DesignTokens.Space.s4 + Self.sideColumnWidth
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s6) {
            StatusSentence(overview: overview, actions: actions)
            if !overview.problems.isEmpty {
                NeedsAttention(problems: overview.problems, actions: actions)
                    .transition(.opacity)
            }
            FlowStrip(stages: overview.stages, rows: width - 2 * DesignTokens.Space.s5 >= FlowStrip.oneRowMinWidth ? 1 : 2)
            let layout = sideBySide
                ? AnyLayout(HStackLayout(alignment: .top, spacing: DesignTokens.Space.s4))
                : AnyLayout(VStackLayout(alignment: .leading, spacing: DesignTokens.Space.s4))
            layout {
                mainColumn
                    .frame(minWidth: sideBySide ? Self.mainColumnMinWidth : nil, maxWidth: .infinity, alignment: .topLeading)
                if hasSideColumn {
                    sideColumn
                        .frame(maxWidth: sideBySide ? Self.sideColumnWidth : .infinity, alignment: .topLeading)
                }
            }
        }
        .padding(DesignTokens.Space.s5)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .animation(reduceMotion ? nil : .standard, value: overview.problems.map(\.id))
    }

    private var hasSideColumn: Bool { !overview.meters.isEmpty || overview.reposLine != nil }

    @ViewBuilder private var mainColumn: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s4) {
            if overview.showsAllCaughtUp {
                AllCaughtUp()
            }
            if !overview.working.isEmpty {
                Card(title: Overview.nowWorkingTitle) {
                    RowList(items: overview.working) { WorkingRowView(row: $0) }
                }
            }
            if !overview.nextUp.isEmpty {
                Card(title: Overview.nextUpTitle) {
                    RowList(items: overview.nextUp) { QueuedRowView(row: $0) }
                }
            }
        }
    }

    @ViewBuilder private var sideColumn: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s4) {
            if !overview.meters.isEmpty {
                Card(title: Overview.todayTitle) {
                    VStack(alignment: .leading, spacing: DesignTokens.Space.s3) {
                        ForEach(overview.meters) { MeterView(meter: $0) }
                    }
                }
            }
            if let line = overview.reposLine {
                Card(title: Overview.reposTitle) {
                    Text(line).font(DesignTokens.TypeStyle.body.font)
                }
            }
        }
    }
}

// MARK: - P1: the status sentence

private struct StatusSentence: View {
    let overview: Overview
    let actions: OverviewActions

    var body: some View {
        HStack(alignment: .center, spacing: DesignTokens.Space.s3) {
            Image(systemName: status.symbol)
                .font(.title2)
                .foregroundStyle(status.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DesignTokens.Space.s1) {
                Text(overview.sentence)
                    .font(DesignTokens.TypeStyle.sentence.font)
                    .accessibilityAddTraits(.isHeader)
                Text(overview.context)
                    .font(DesignTokens.TypeStyle.callout.font)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: DesignTokens.Space.s4)
            if overview.showsResume {
                Button(Overview.resumeTitle, action: actions.resume)
                    .buttonStyle(.borderedProminent)
                    .disabled(actions.controlInFlight != nil)
            }
        }
    }

    private var status: DesignTokens.Status {
        switch overview.mood {
        case .flowing, .idle: .done
        case .attention: .problem
        case .paused: .idle
        }
    }
}

// MARK: - P2, C5, C6: the flow strip

private struct FlowStrip: View {
    let stages: [Overview.Stage]
    /// One row when six tiles fit with their context on one line, else two rows of three, in reading order.
    let rows: Int

    /// Six tiles of 140 pt and their chevrons.
    static let oneRowMinWidth: CGFloat = 6 * 140 + 5 * 20

    var body: some View {
        let perRow = (stages.count + rows - 1) / max(rows, 1)
        VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
            ForEach(0..<rows, id: \.self) { row in
                HStack(alignment: .center, spacing: DesignTokens.Space.s1) {
                    let slice = Array(stages.enumerated()).dropFirst(row * perRow).prefix(perRow)
                    ForEach(Array(slice), id: \.element.id) { index, stage in
                        if index % perRow > 0 {
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                        }
                        StatTile(stage: stage)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// C5: a count, its label and one line of context; tertiary at 0, tinted only for Waiting on you.
private struct StatTile: View {
    let stage: Overview.Stage
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s1) {
            HStack(spacing: DesignTokens.Space.s1) {
                if stage.isTinted {
                    Image(systemName: DesignTokens.Status.you.symbol).foregroundStyle(DesignTokens.Status.you.tint)
                }
                Text(stage.title)
            }
            .font(DesignTokens.TypeStyle.label.font)
            .foregroundStyle(stage.isZero ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
            .lineLimit(1)
            Text(stage.count, format: .number)
                .font(DesignTokens.TypeStyle.figure.font)
                .foregroundStyle(stage.isZero ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                .contentTransition(.numericText(value: Double(stage.count)))
                .animation(reduceMotion ? nil : .standard, value: stage.count)
            Text(stage.context)
                .font(DesignTokens.TypeStyle.callout.font)
                .foregroundStyle(stage.isZero ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
                .lineLimit(2, reservesSpace: true)
        }
        .padding(DesignTokens.Space.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.row, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.row, style: .continuous)
                .strokeBorder(DesignTokens.Surface.separator.color)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(stage.accessibilityLabel)
    }

    private var background: AnyShapeStyle {
        guard stage.isTinted else { return AnyShapeStyle(DesignTokens.Surface.content.color) }
        return AnyShapeStyle(DesignTokens.Status.you.tint.opacity(DesignTokens.Status.badgeTint(dark: colorScheme == .dark)))
    }
}

// MARK: - P3, C9: Needs attention

private struct NeedsAttention: View {
    let problems: [Overview.Problem]
    let actions: OverviewActions
    @State private var hovering = false
    /// The order shown; a poll keeps it while the pointer is over the list.
    @State private var order: [String] = []

    var body: some View {
        Card(title: Overview.needsAttentionTitle) {
            RowList(items: shown) { AttentionRow(problem: $0, actions: actions) }
        }
        .onHover { hovering = $0 }
        .onAppear { order = problems.map(\.id) }
        .onChange(of: problems.map(\.id)) { _, ids in
            order = hovering ? Overview.holdingOrder(ids, previous: order) : ids
        }
    }

    private var shown: [Overview.Problem] {
        let byID = Dictionary(problems.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let ordered = Overview.holdingOrder(problems.map(\.id), previous: order)
        return ordered.compactMap { byID[$0] }
    }
}

/// C9: the severity symbol, the sentence, its age and its fixes, the first one prominent.
private struct AttentionRow: View {
    let problem: Overview.Problem
    let actions: OverviewActions

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.s3) {
            Image(systemName: status.symbol)
                .foregroundStyle(status.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DesignTokens.Space.s1 / 2) {
                Text(problem.sentence)
                    .font(DesignTokens.TypeStyle.body.font)
                    .fixedSize(horizontal: false, vertical: true)
                if let note = problem.note {
                    Text(note)
                        .font(DesignTokens.TypeStyle.callout.font)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: DesignTokens.Space.s2)
            if let age = problem.age {
                Text(age)
                    .font(DesignTokens.TypeStyle.callout.font)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            ForEach(Array(problem.fixes.enumerated()), id: \.element) { index, fix in
                FixButton(fix: fix, prominent: index == 0, actions: actions)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(problem.sentence + (problem.age.map { ", \($0)" } ?? ""))
        .accessibilityActions {
            ForEach(problem.fixes, id: \.self) { fix in
                Button(fix.title) { actions.perform(fix) }
            }
        }
    }

    private var status: DesignTokens.Status {
        problem.severity == .problem ? .problem : .you
    }
}

private struct FixButton: View {
    let fix: Overview.Fix
    let prominent: Bool
    let actions: OverviewActions

    var body: some View {
        let button = Button(fix.title) { actions.perform(fix) }
            .disabled(disabled)
            .fixedSize()
        if prominent {
            button.buttonStyle(.borderedProminent)
        } else {
            button.buttonStyle(.bordered)
        }
    }

    private var disabled: Bool {
        if case let .stopForcing(identifier) = fix { return actions.controlInFlight == .stopForcing(identifier) }
        return false
    }
}

// MARK: - C8: Now working and Next up

/// Rows split by hairlines.
private struct RowList<Item: Identifiable, Row: View>: View {
    let items: [Item]
    @ViewBuilder let row: (Item) -> Row

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index > 0 { Divider() }
                row(item).padding(.vertical, DesignTokens.Space.s2)
            }
        }
    }
}

private struct WorkingRowView: View {
    let row: Overview.WorkingRow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.s3) {
            symbol
            VStack(alignment: .leading, spacing: DesignTokens.Space.s1 / 2) {
                TicketTitle(identifier: row.identifier, title: row.title, repoKey: row.repoKey)
                Text(row.detail)
                    .font(DesignTokens.TypeStyle.callout.font)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                if let message = row.lastMessage {
                    Text(message)
                        .font(DesignTokens.TypeStyle.callout.font)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: DesignTokens.Space.s2)
            VStack(alignment: .trailing, spacing: DesignTokens.Space.s1 / 2) {
                if let time = row.runningTime {
                    Text(time).font(DesignTokens.TypeStyle.callout.font).monospacedDigit()
                }
                if let tokens = row.tokens {
                    Text(tokens)
                        .font(DesignTokens.TypeStyle.callout.font)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
            }
            .fixedSize()
        }
        .contentShape(Rectangle())
        .contextMenu {
            if let url = row.url {
                Button("Open in Linear") { openURL(url) }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder private var symbol: some View {
        if row.isStuck {
            Image(systemName: DesignTokens.Status.problem.symbol)
                .foregroundStyle(DesignTokens.Status.problem.tint)
                .accessibilityHidden(true)
        } else {
            // motion.live: only here and only while drawn; Reduce Motion stops the loop.
            Image(systemName: DesignTokens.Status.working.symbol)
                .foregroundStyle(DesignTokens.Status.working.tint)
                .symbolEffect(.variableColor.iterative, isActive: !reduceMotion)
                .accessibilityHidden(true)
        }
    }

    private var accessibilityLabel: String {
        var parts = [row.identifier]
        if let title = row.title { parts.append(title) }
        if let repo = row.repoKey { parts.append(repo) }
        parts.append(row.isStuck ? "needs attention, \(row.detail)" : row.detail)
        if let time = row.runningTime { parts.append(time) }
        return parts.joined(separator: ", ")
    }
}

private struct QueuedRowView: View {
    let row: Overview.QueuedRow

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.s3) {
            Image(systemName: "clock")
                .foregroundStyle(DesignTokens.Status.idle.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DesignTokens.Space.s1 / 2) {
                TicketTitle(identifier: row.identifier, title: row.title, repoKey: row.repoKey)
                Text(row.reason)
                    .font(DesignTokens.TypeStyle.callout.font)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([row.identifier, row.title, row.repoKey, row.reason].compactMap { $0 }.joined(separator: ", "))
    }
}

/// A ticket is always its identifier and its title together, with its repo after them.
private struct TicketTitle: View {
    let identifier: String
    let title: String?
    let repoKey: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.s2) {
            Text(identifier).font(DesignTokens.TypeStyle.rowTitle.font)
            if let title {
                Text(title).font(DesignTokens.TypeStyle.body.font).lineLimit(1)
            }
            if let repoKey {
                Text(repoKey)
                    .font(DesignTokens.TypeStyle.callout.font)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

private struct AllCaughtUp: View {
    var body: some View {
        HStack(spacing: DesignTokens.Space.s3) {
            Image(systemName: DesignTokens.Status.done.symbol)
                .font(.title2)
                .foregroundStyle(DesignTokens.Status.done.tint)
                .accessibilityHidden(true)
            Text(Overview.allCaughtUp).font(DesignTokens.TypeStyle.section.font)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, DesignTokens.Space.s8)
    }
}

// MARK: - C11: meters

private struct MeterView: View {
    let meter: Overview.Meter

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s1) {
            HStack(alignment: .firstTextBaseline) {
                Text(meter.label).font(DesignTokens.TypeStyle.body.font)
                Spacer(minLength: DesignTokens.Space.s2)
                Text(meter.value)
                    .font(DesignTokens.TypeStyle.callout.font)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            if let fraction = meter.fraction {
                MeterBar(fraction: fraction, tint: tint)
            }
            if let note = meter.note {
                Text(note)
                    .font(DesignTokens.TypeStyle.caption.font)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(meter.accessibilityLabel + (meter.note.map { ", \($0)" } ?? ""))
    }

    private var tint: Color {
        switch meter.level {
        case .normal: DesignTokens.SystemColor.accent.color
        case .near: DesignTokens.Status.you.tint
        case .atLimit: DesignTokens.Status.problem.tint
        }
    }
}

/// A meter's bar: the fill carries the level, on a track that is a light step of the same hue (design system §3.3).
/// Drawn rather than a `Gauge`, whose AppKit control doesn't render offscreen.
private struct MeterBar: View {
    let fraction: Double
    let tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(tint.opacity(0.2))
                Capsule()
                    .fill(tint)
                    .frame(width: max(proxy.size.width * fraction, fraction > 0 ? proxy.size.height : 0))
            }
        }
        .frame(height: 6)
        .animation(reduceMotion ? nil : .standard, value: fraction)
        .accessibilityHidden(true)
    }
}
