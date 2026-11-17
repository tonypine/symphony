import SwiftUI
import SymphonyBarCore

// The catalog's Facts rail, its first two panels (`docs/design/director-ticket-page.md` §1 facts 9, 10, 15, 16 and
// 21, as `docs/design/director-window-and-home.md` § The ticket page changed them): the Pull request panel (the PR with
// its size and the state of its checks, then every check under its workflow's name, with its state and how long it
// took, each row opening its log) and the Connected panel (the epic with its progress and the tickets around this one,
// the tickets that block it now and the tickets it holds up, each on one line). A part with nothing to list is left
// out, and a ticket connected to nothing has no Connected panel. Each panel's title sits outside its card; the panels
// never fold. Rows hover, press, take the focus ring and nudge their arrow 2 pt right under the pointer.

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
                    Badge(status: model.stateStatus, word: model.state)
                    Spacer(minLength: 0)
                }
                let meta = [model.head, model.size].compactMap { $0 }
                if !meta.isEmpty {
                    Text(meta.joined(separator: " · "))
                        .font(DesignTokens.TypeStyle.secondary.font)
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
                Badge(status: model.checksStatus, word: model.checksBadge)
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
                    // The workflow's own name, upper case in the zone style: the app keeps no table of names.
                    ZoneTitle(group.name)
                        .padding(.leading, -DesignTokens.Space.s1)
                        .padding(.top, DesignTokens.Space.s1)
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
                    .font(DesignTokens.TypeStyle.secondary.font)
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
        case .running: StatusDot(.working, live: true)
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

    /// `openTicket` opens another ticket's page; `openInitiatives` the epic's place in Initiatives.
    public init(model: ConnectedPanelModel, openTicket: @escaping (String) -> Void, openInitiatives: @escaping () -> Void) {
        self.model = model
        self.openTicket = openTicket
        self.openInitiatives = openInitiatives
    }

    public var body: some View {
        if !model.isEmpty {
            FactsPanel(title: "Connected") {
                if let epic = model.epic {
                    SubPanel(title: "Epic") {
                        EpicBlock(epic: epic, openInitiatives: openInitiatives, openTicket: openTicket)
                    }
                }
                if !model.waitingOn.isEmpty {
                    SubPanel(title: "Waiting on") { TicketLines(lines: model.waitingOn, open: openTicket) }
                }
                if !model.holdingUp.isEmpty {
                    SubPanel(title: "Holding up") { TicketLines(lines: model.holdingUp, open: openTicket) }
                }
            }
        }
    }
}

/// The epic: its identifier and title (two lines at most, the whole title in its tooltip), opening Initiatives; its
/// progress strip (C51) across the panel, "4 of 7 done · this is the 5th" under it, then the tickets around this one.
private struct EpicBlock: View {
    let epic: ConnectedPanelModel.Epic
    let openInitiatives: () -> Void
    let openTicket: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
            FactRow(action: openInitiatives) {
                HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.s2) {
                    Text(epic.identifier)
                        .font(DesignTokens.TypeStyle.secondary.font.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .fixedSize()
                    Text(epic.title)
                        .font(DesignTokens.TypeStyle.rowTitle.font)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: DesignTokens.Space.s2)
                    RowArrow()
                }
            }
            .help(epic.title)
            .accessibilityLabel(epic.accessibilityLabel)
            .accessibilityHint("Opens Initiatives")
            VStack(alignment: .leading, spacing: DesignTokens.Space.s1) {
                if let strip = epic.strip {
                    ProgressStrip(strip.items, label: strip.accessibilityLabel)
                }
                Text(epic.progressLine)
                    .font(DesignTokens.TypeStyle.secondary.font)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            if !epic.tickets.isEmpty {
                TicketLines(lines: epic.tickets, open: openTicket)
            }
        }
    }
}

/// Tickets one under the other, each a one-line Row.
private struct TicketLines: View {
    let lines: [ConnectedPanelModel.Line]
    let open: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Tree.lineGap) {
            ForEach(lines) { TicketLine(line: $0, open: open) }
        }
    }
}

/// A ticket on one line (C49): its status dot, identifier, title cut with an ellipsis (the whole title in its tooltip)
/// and its situation's badge. Another ticket opens its page; this ticket is highlighted and opens nothing.
private struct TicketLine: View {
    let line: ConnectedPanelModel.Line
    let open: (String) -> Void

    var body: some View {
        let action: (() -> Void)? = line.current ? nil : { open(line.identifier) }
        Row(
            line.title, identifier: line.identifier, lead: .dot(line.status, live: false), current: line.current,
            select: action, open: action
        ) {
            if let badge = line.badge {
                Badge(status: line.status, word: badge, size: .small)
            }
            if !line.current {
                RowArrow()
            }
        }
        // The row's inset bleeds past the panel's edge, so its dot lines up with the epic's title.
        .padding(.horizontal, -DesignTokens.Row.sideInset)
        .help(line.title)
        .accessibilityLabel(line.accessibilityLabel)
        .accessibilityHint(line.current ? "" : "Opens its ticket")
    }
}

// MARK: - Shared pieces

/// A panel of the facts rail: its zone title above it (`TitledPanel`).
struct FactsPanel<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        TitledPanel(title: title) { content }
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
            .font(DesignTokens.TypeStyle.secondary.font)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The row's arrow: it slides 2 pt right while the pointer is over the row.
struct RowArrow: View {
    @Environment(\.rowHovered) private var hovered
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
                .environment(\.rowHovered, hovered)
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
