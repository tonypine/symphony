import SwiftUI
import SymphonyBarCore

// The catalog's Facts rail, its first two panels (`docs/design/director-ticket-page.md` §1 facts 9, 10, 15, 16 and
// 21): the Pull request panel (the PR with its size and the state of its checks, then every check by workflow with
// its state and how long it took, each row opening its log) and the Connected panel (the epic with its progress, the
// tickets this one waits on, open or struck through once resolved, and the tickets it holds up). Each panel's title
// sits outside its card; the panels never fold. Rows are the catalog's Row: hover and pressed overlays, the focus
// ring, and the arrow nudging 2 pt right under the pointer.

/// The rail's widths: a laptop's column and a desktop's.
public enum FactsRail {
    public static let laptopWidth: CGFloat = 340
    public static let desktopWidth: CGFloat = 440
}

// MARK: - The Pull request panel

public struct PullRequestPanel: View {
    let model: PullRequestPanelModel?
    let open: (URL) -> Void

    /// `model` nil for a ticket without a pull request; `open` opens the PR or a check's log.
    public init(model: PullRequestPanelModel?, open: @escaping (URL) -> Void) {
        self.model = model
        self.open = open
    }

    public var body: some View {
        FactsPanel(title: "Pull request") {
            if let model {
                PullRequestLine(model: model, open: open)
                ChecksBlock(model: model, open: open)
            } else {
                EmptyLine(text: PullRequestPanelModel.emptyLine)
            }
        }
    }
}

/// The PR itself: its glyph and number, its state, its head and size; it opens the PR.
private struct PullRequestLine: View {
    let model: PullRequestPanelModel
    let open: (URL) -> Void

    var body: some View {
        FactRow(url: model.url, open: open) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.s2) {
                    Image(systemName: "arrow.triangle.pull")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(model.stateStatus.tint)
                        .accessibilityHidden(true)
                    Text(model.name)
                        .font(DesignTokens.TypeStyle.rowTitle.font)
                        .fixedSize()
                    StatusBadge(status: model.stateStatus, word: model.state)
                    Spacer(minLength: 0)
                }
                let meta = [model.head, model.size].compactMap { $0 }
                if !meta.isEmpty {
                    Text(meta.joined(separator: " · "))
                        .font(DesignTokens.TypeStyle.callout.font)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityLabel(model.accessibilityLabel)
    }
}

/// "Checks" with the one-line summary and its badge, then each workflow's checks.
private struct ChecksBlock: View {
    let model: PullRequestPanelModel
    let open: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
            HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.s2) {
                Text("Checks")
                    .font(DesignTokens.TypeStyle.label.font)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: DesignTokens.Space.s2)
                StatusBadge(status: model.checksStatus, word: model.checksBadge)
            }
            if let line = model.checksLine {
                Text(line)
                    .font(DesignTokens.TypeStyle.caption.font)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(model.groups) { group in
                VStack(alignment: .leading, spacing: DesignTokens.Space.s1) {
                    Text(group.name)
                        .font(DesignTokens.TypeStyle.caption.font.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, DesignTokens.Space.s1)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(group.checks) { check in
                        CheckRow(check: check, open: open)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(group.name)
            }
        }
    }
}

/// One check: its state's mark (the live dot while it runs), its name, its state word and how long it took.
private struct CheckRow: View {
    let check: PullRequestPanelModel.Check
    let open: (URL) -> Void

    var body: some View {
        FactRow(url: check.url, open: open) {
            HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.s2) {
                mark
                    .frame(width: 14)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                    .accessibilityHidden(true)
                Text(check.name)
                    .font(DesignTokens.TypeStyle.callout.font)
                    .fontWeight(check.state == .failed ? .semibold : .regular)
                    .foregroundStyle(check.state == .skipped ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: DesignTokens.Space.s2)
                Text(check.word)
                    .font(DesignTokens.TypeStyle.caption.font.weight(.medium))
                    .foregroundStyle(check.state == .failed ? AnyShapeStyle(check.status.tint) : AnyShapeStyle(.secondary))
                    .fixedSize()
                Text(check.duration ?? "")
                    .font(DesignTokens.TypeStyle.caption.font)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(minWidth: 58, alignment: .trailing)
                    .fixedSize()
            }
        }
        .background {
            if check.state == .failed {
                RoundedRectangle(cornerRadius: DesignTokens.Radius.row, style: .continuous)
                    .fill(check.status.tint.opacity(0.1))
                    .padding(EdgeInsets(top: -2, leading: -DesignTokens.Space.s1, bottom: -2, trailing: -DesignTokens.Space.s1))
            }
        }
        .accessibilityLabel(check.accessibilityLabel)
        .accessibilityHint(check.url == nil ? "" : "Opens its log on GitHub")
    }

    @ViewBuilder private var mark: some View {
        switch check.state {
        case .running: LiveDot(size: 7)
        case .passed: Image(systemName: "checkmark.circle.fill").font(.system(size: 11)).foregroundStyle(check.status.tint)
        case .failed: Image(systemName: "xmark.octagon.fill").font(.system(size: 11)).foregroundStyle(check.status.tint)
        case .waiting: Image(systemName: "clock").font(.system(size: 11)).foregroundStyle(.tertiary)
        case .skipped: Image(systemName: "chevron.right.circle").font(.system(size: 11)).foregroundStyle(.tertiary)
        case .cancelledNoMachine: Image(systemName: "circle.slash").font(.system(size: 11)).foregroundStyle(.tertiary)
        }
    }
}

// MARK: - The Connected panel

public struct ConnectedPanel: View {
    let model: ConnectedPanelModel
    let openTicket: (String) -> Void
    let openInitiatives: () -> Void

    /// `openTicket` opens a blocker's or a held ticket's page; `openInitiatives` the epic's place in Initiatives.
    public init(model: ConnectedPanelModel, openTicket: @escaping (String) -> Void, openInitiatives: @escaping () -> Void) {
        self.model = model
        self.openTicket = openTicket
        self.openInitiatives = openInitiatives
    }

    public var body: some View {
        FactsPanel(title: "Connected") {
            SubPanel(title: "Epic") {
                if let epic = model.epic {
                    EpicRow(epic: epic, open: openInitiatives)
                } else {
                    EmptyLine(text: ConnectedPanelModel.noEpicLine)
                }
            }
            SubPanel(title: "Waiting on") {
                if model.waitingOn.isEmpty {
                    EmptyLine(text: ConnectedPanelModel.noBlockerLine)
                } else {
                    ForEach(model.waitingOn) { TicketRow(row: $0, open: openTicket) }
                }
            }
            SubPanel(title: "Holding up") {
                if model.holdingUp.isEmpty {
                    EmptyLine(text: ConnectedPanelModel.holdsNothingLine)
                } else {
                    ForEach(model.holdingUp) { TicketRow(row: $0, open: openTicket) }
                }
            }
        }
    }
}

/// The epic: its identifier and title, opening Initiatives; its progress strip (N10) and count under it.
private struct EpicRow: View {
    let epic: ConnectedPanelModel.Epic
    let open: () -> Void

    var body: some View {
        FactRow(action: open) {
            VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
                HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.s2) {
                    Text(epic.identifier)
                        .font(DesignTokens.TypeStyle.callout.font.weight(.semibold))
                        .monospacedDigit()
                        .fixedSize()
                    Text(epic.title)
                        .font(DesignTokens.TypeStyle.callout.font)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: DesignTokens.Space.s2)
                    RowArrow()
                }
                HStack(spacing: DesignTokens.Space.s2) {
                    if let strip = epic.strip {
                        HStack(spacing: ProgressStrip.gap) {
                            ForEach(Array(strip.segments.enumerated()), id: \.offset) { _, segment in
                                RoundedRectangle(cornerRadius: ProgressStrip.segmentHeight / 2, style: .continuous)
                                    .fill(segment.color.color)
                                    .frame(minWidth: 3, maxWidth: ProgressStrip.segmentWidth)
                                    .frame(height: ProgressStrip.segmentHeight)
                            }
                        }
                        .frame(maxWidth: ProgressStrip.segmentWidth * Double(strip.segments.count) + ProgressStrip.gap * Double(max(strip.segments.count - 1, 0)))
                    }
                    Text(epic.progress)
                        .font(DesignTokens.TypeStyle.callout.font)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .fixedSize()
                }
            }
        }
        .accessibilityLabel(epic.accessibilityLabel)
        .accessibilityHint("Opens Initiatives")
    }
}

/// A ticket it waits on or holds up: its status dot, identifier and title, where it stands; struck through once a
/// blocker resolved.
private struct TicketRow: View {
    let row: ConnectedPanelModel.Row
    let open: (String) -> Void

    var body: some View {
        FactRow(action: { open(row.identifier) }) {
            HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.s2) {
                Circle()
                    .fill(row.status.tint)
                    .frame(width: 7, height: 7)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.s2) {
                        Text(row.identifier)
                            .font(DesignTokens.TypeStyle.callout.font.weight(.semibold))
                            .monospacedDigit()
                            .strikethrough(row.struck)
                            .foregroundStyle(row.struck ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                            .fixedSize()
                        Text(row.title)
                            .font(DesignTokens.TypeStyle.callout.font)
                            .strikethrough(row.struck)
                            .foregroundStyle(row.struck ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !row.detail.isEmpty {
                        Text(row.detail)
                            .font(DesignTokens.TypeStyle.caption.font)
                            .fontWeight(row.struck ? .regular : .medium)
                            .foregroundStyle(row.struck || row.status == .idle ? AnyShapeStyle(.secondary) : AnyShapeStyle(row.status.tint))
                            .monospacedDigit()
                    }
                }
                Spacer(minLength: DesignTokens.Space.s2)
                RowArrow()
            }
        }
        .accessibilityLabel(row.accessibilityLabel)
        .accessibilityHint("Opens its ticket")
    }
}

// MARK: - Shared pieces

/// A panel: its title outside the card, then the card with its parts one under the other.
struct FactsPanel<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
            Text(title)
                .font(DesignTokens.TypeStyle.section.font)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: DesignTokens.Space.s4) {
                content
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
            .accessibilityLabel(title)
        }
    }
}

struct SubPanel<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
            Text(title)
                .font(DesignTokens.TypeStyle.label.font)
                .accessibilityAddTraits(.isHeader)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

/// A fact that is unknown or absent, said in a plain line, never a dash.
struct EmptyLine: View {
    let text: String

    var body: some View {
        Text(text)
            .font(DesignTokens.TypeStyle.callout.font)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The row's arrow: it slides 2 pt right while the pointer is over the row.
struct RowArrow: View {
    @Environment(\.factRowHovered) private var hovered
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.tertiary)
            .offset(x: hovered && !reduceMotion ? FactRowStyle.nudge : 0)
            .animation(.motion(.fast, reduceMotion: reduceMotion), value: hovered)
            .accessibilityHidden(true)
    }
}

extension EnvironmentValues {
    /// True while the pointer is over the fact row the view sits in.
    @Entry var factRowHovered = false
}

/// A fact row as a button: it opens `url` with `open`, or runs `action`; a row with neither is plain text.
struct FactRow<Label: View>: View {
    var url: URL?
    var open: ((URL) -> Void)?
    var action: (() -> Void)?
    @ViewBuilder let label: Label

    init(url: URL?, open: @escaping (URL) -> Void, @ViewBuilder label: () -> Label) {
        self.url = url
        self.open = open
        self.label = label()
    }

    init(action: @escaping () -> Void, @ViewBuilder label: () -> Label) {
        self.action = action
        self.label = label()
    }

    var body: some View {
        if let perform = perform {
            Button(action: perform) {
                label.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(FactRowStyle())
            .focusEffectDisabled()
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
        } else {
            label
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .ignore)
        }
    }

    private var perform: (() -> Void)? {
        if let action { return action }
        guard let url, let open else { return nil }
        return { open(url) }
    }
}

/// The catalog's Row as a button style: hover and pressed overlays bleeding past the row, the focus ring on its edge,
/// the press settling it to 99.5 %, and its arrow nudged right under the pointer.
struct FactRowStyle: ButtonStyle {
    /// How far the arrow slides under the pointer.
    static let nudge: CGFloat = 2

    func makeBody(configuration: Configuration) -> some View {
        Face(configuration: configuration)
    }

    private struct Face: View {
        let configuration: Configuration
        @State private var hovered = false
        @Environment(\.isFocused) private var isFocused
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .environment(\.factRowHovered, hovered)
                .modifier(RowFace(
                    state: DesignTokens.Interaction(hovered: hovered, pressed: configuration.isPressed, focused: isFocused),
                    reduceMotion: reduceMotion,
                    bleed: EdgeInsets(top: 3, leading: DesignTokens.Space.s2, bottom: 3, trailing: DesignTokens.Space.s2)
                ))
                .onHover { hovered = $0 }
        }
    }
}

// The facts rail's cards draw again only when their model changed: the actions they are given are the page's, and a
// new closure for the same action doesn't open the gate (TP-1480).

extension PullRequestPanel: Equatable {
    nonisolated public static func == (lhs: PullRequestPanel, rhs: PullRequestPanel) -> Bool { lhs.model == rhs.model }
}

extension ConnectedPanel: Equatable {
    nonisolated public static func == (lhs: ConnectedPanel, rhs: ConnectedPanel) -> Bool { lhs.model == rhs.model }
}
