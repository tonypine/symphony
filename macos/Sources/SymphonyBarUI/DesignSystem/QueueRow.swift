import AppKit
import SwiftUI
import SymphonyBarCore

// The Home queue's row (TP-1608, `.vlist .row` in `docs/design/prototypes/home-queue/page.css`): one ticket of the
// queue on one line. Its position number, centred in a cell only as wide as the widest number on screen; its state
// glyph; its identifier in a fixed column and its title; then the ticket it waits on, its badges and its repo. Under
// the pointer the drag handle takes the number's place and Start takes the repo's, in the same cells, so nothing
// shifts. A dragged row is lifted on the content surface, its handle in the accent.

/// What a queue row says about its ticket.
public struct QueueRowModel: Equatable, Identifiable {
    public struct Mark: Equatable {
        public var status: DesignTokens.Status
        public var word: String

        public init(_ status: DesignTokens.Status, _ word: String) {
            self.status = status
            self.word = word
        }
    }

    public var id: String { identifier }
    /// Its place in the queue, from 1.
    public var number: Int
    public var identifier: String
    public var title: String
    /// The state glyph: the working dot, a pause, a clock, the person.
    public var lead: RowLead
    /// The ticket it starts after, while that one is still open.
    public var after: String?
    /// Its badges: what waits on the person, its state ("Code Review", "Stopped in Coding").
    public var marks: [Mark]
    public var repo: String
    /// The number as the read writes it when it is not a whole one: a sub-ticket's "6.1"; nil draws `number`.
    public var label: String?

    /// The number the row shows: "1,243", or a sub-ticket's "6.1".
    public var numberText: String { label ?? DesignTokens.HomeQueue.number(number) }

    public init(
        number: Int, identifier: String, title: String, lead: RowLead, after: String? = nil, marks: [Mark] = [], repo: String,
        label: String? = nil
    ) {
        self.label = label
        self.number = number
        self.identifier = identifier
        self.title = title
        self.lead = lead
        self.after = after
        self.marks = marks
        self.repo = repo
    }
}

public struct QueueRow: View {
    /// How a row is drawn: at rest, under the pointer, or dragged.
    public enum Look: String, CaseIterable, Equatable {
        case rest, hover, dragged
    }

    /// The row's parts, each in its own cell.
    public enum Part: String, CaseIterable, Hashable {
        case number, handle, lead, identifier, title, after, marks, repo, start
    }

    let row: QueueRowModel
    let numberWidth: CGFloat
    let look: Look?
    let reorderable: Bool
    let picked: Bool
    let onStart: () -> Void
    @State private var hovered = false
    @Environment(\.queueRowProbes) private var probes

    /// The row of `row`, its number centred in a cell `numberWidth` wide (`numberWidth(widest:)` of the numbers on
    /// screen). `look` draws one look still, for a story; nil follows the pointer. A row that may not be `reorderable`
    /// (a saved view is picked) keeps its number under the pointer and shows no handle. A `picked` row is the one being
    /// dragged, left behind in its place and dimmed (`.row.dragging`).
    public init(
        _ row: QueueRowModel, numberWidth: CGFloat, look: Look? = nil, reorderable: Bool = true, picked: Bool = false,
        onStart: @escaping () -> Void = {}
    ) {
        self.row = row
        self.numberWidth = numberWidth
        self.look = look
        self.reorderable = reorderable
        self.picked = picked
        self.onStart = onStart
    }

    /// The number cell's width for the widest number on screen: its digits in the secondary style's tabular figures,
    /// at least two.
    public static func numberWidth(widest: Int) -> CGFloat {
        let font = NSFont.monospacedDigitSystemFont(
            ofSize: DesignTokens.TypeStyle.secondary.nsFont.pointSize,
            weight: NSFont.Weight(rawValue: CGFloat(DesignTokens.TypeStyle.secondary.systemWeight))
        )
        let template = DesignTokens.HomeQueue.numberTemplate(widest: widest) as NSString
        return ceil(template.size(withAttributes: [.font: font]).width)
    }

    /// The identifier's column: eight figures of the row title's style, so every title starts at one place.
    public static var identifierWidth: CGFloat {
        let font = NSFont.monospacedDigitSystemFont(
            ofSize: DesignTokens.TypeStyle.rowTitle.nsFont.pointSize,
            weight: NSFont.Weight(rawValue: CGFloat(DesignTokens.TypeStyle.rowTitle.systemWeight))
        )
        let template = String(repeating: "0", count: DesignTokens.HomeQueue.identifierCharacters) as NSString
        return ceil(template.size(withAttributes: [.font: font]).width)
    }

    /// The look drawn: the one asked for, or the pointer's.
    private var shown: Look { look ?? (hovered ? .hover : .rest) }

    /// Whether the handle is shown in place of the number: under the pointer and while dragged, in a row that may be
    /// reordered.
    public static func handles(_ look: Look, reorderable: Bool = true) -> Bool { reorderable && look != .rest }
    /// Whether Start stands in the repo's place: under the pointer only (a dragged row keeps its repo).
    public static func starts(_ look: Look) -> Bool { look == .hover }

    public var body: some View {
        let queue = DesignTokens.HomeQueue.self
        let shape = RoundedRectangle(cornerRadius: DesignTokens.Radius.row, style: .continuous)
        let look = shown
        HStack(spacing: queue.rowPartGap) {
            numberCell(look)
            RowLeadMark(lead: row.lead)
                .frame(width: DesignTokens.Row.leadSize, height: DesignTokens.Row.leadSize)
                .padding(.horizontal, queue.leadMargin)
                .probe(.lead, probes)
                .accessibilityHidden(true)
            HStack(spacing: queue.rowMainGap) {
                Text(row.identifier)
                    .textStyle(.rowTitle)
                    .monospacedDigit()
                    .fixedSize()
                    .foregroundStyle(DesignTokens.TextColor.secondary.color)
                    .frame(minWidth: Self.identifierWidth, alignment: .leading)
                    .probe(.identifier, probes)
                Text(row.title)
                    .font(DesignTokens.TypeStyle.font(size: DesignTokens.TypeStyle.rowTitle.size, weight: DesignTokens.Row.titleWeight))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(DesignTokens.TextColor.primary.color)
                    .probe(.title, probes)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trail(look)
        }
        .padding(.horizontal, queue.rowInset)
        .frame(maxWidth: .infinity)
        .frame(height: queue.rowHeight)
        .background { face(look, shape) }
        .contentShape(shape)
        .opacity(picked ? DesignTokens.HomeQueue.draggedOpacity : 1)
        .onHover { hovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Number \(row.numberText), \(row.identifier), \(row.title)")
        .accessibilityAction(named: "Start") { onStart() }
    }

    @ViewBuilder private func face(_ look: Look, _ shape: RoundedRectangle) -> some View {
        switch look {
        case .rest: EmptyView()
        case .hover: shape.fill(DesignTokens.StateSurface.hover.fill)
        case .dragged:
            shape.fill(DesignTokens.Surface.content.color)
                .elevation(DesignTokens.HomeQueue.dragElevation, in: shape)
        }
    }

    /// The number, and the handle in the same cell under the pointer.
    private func numberCell(_ look: Look) -> some View {
        let queue = DesignTokens.HomeQueue.self
        let handle = Self.handles(look, reorderable: reorderable)
        return ZStack {
            Text(row.numberText)
                .textStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(DesignTokens.TextColor.tertiary.color)
                .opacity(handle ? 0 : 1)
                .probe(.number, probes)
            ReorderGrip()
                .fill((look == .dragged ? DesignTokens.ColorToken.accentText : DesignTokens.TextColor.secondary).color)
                .frame(width: queue.gripHeight, height: queue.gripHeight)
                .frame(width: queue.gripWidth, height: queue.gripHeight)
                .clipped()
                .opacity(handle ? 1 : 0)
                .probe(.handle, probes)
                .accessibilityHidden(true)
        }
        .frame(width: numberWidth, height: queue.numberHeight)
    }

    /// The ticket it waits on, its badges, then the repo, and Start in the repo's cell under the pointer.
    private func trail(_ look: Look) -> some View {
        let queue = DesignTokens.HomeQueue.self
        let starts = Self.starts(look)
        return HStack(spacing: queue.rowMainGap) {
            if let after = row.after {
                HStack(spacing: DesignTokens.Space.s1) {
                    Image(systemName: queue.afterSymbol)
                        .font(DesignTokens.TypeStyle.font(size: queue.afterGlyph, weight: DesignTokens.TypeStyle.label.weight))
                    Text(after).textStyle(.secondary).monospacedDigit()
                }
                .foregroundStyle(DesignTokens.TextColor.tertiary.color)
                .fixedSize()
                .help("Starts when \(after) lands")
                .probe(.after, probes)
            }
            if !row.marks.isEmpty {
                HStack(spacing: queue.rowMainGap) {
                    ForEach(Array(row.marks.enumerated()), id: \.offset) { _, mark in
                        Badge(status: mark.status, word: mark.word, size: .small)
                    }
                }
                .fixedSize()
                .probe(.marks, probes)
            }
            ZStack(alignment: .trailing) {
                Text(row.repo)
                    .textStyle(.secondary)
                    .lineLimit(1)
                    .foregroundStyle(DesignTokens.TextColor.tertiary.color)
                    .opacity(starts ? 0 : 1)
                    .probe(.repo, probes)
                Button("Start", action: onStart)
                    .directorButton(.secondary, size: .small)
                    .frame(width: queue.endWidth)
                    .opacity(starts ? 1 : 0)
                    .allowsHitTesting(starts)
                    .accessibilityHidden(!starts)
                    .probe(.start, probes)
            }
            .frame(width: queue.endWidth, height: queue.endHeight, alignment: .trailing)
        }
        .fixedSize()
    }
}

/// The line in the gap a dragged row lands in (`.drop-line`): 2 pt of the accent with its glow, inset by the row's room at
/// both ends, in the 2 pt between the row above and the one below.
public struct QueueDropLine: View {
    public init() {}

    public var body: some View {
        let queue = DesignTokens.HomeQueue.self
        let shape = RoundedRectangle(cornerRadius: queue.dropLineRadius, style: .continuous)
        shape.fill(queue.dropColor.color)
            .frame(height: queue.dropLineHeight)
            .background { AccentGlow(shape: shape) }
            .padding(.horizontal, queue.rowInset)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// `--accent-glow` around `shape`, outside it only, as a CSS box-shadow draws.
struct AccentGlow<S: Shape>: View {
    let shape: S

    var body: some View {
        let queue = DesignTokens.HomeQueue.self
        ZStack {
            ForEach(Array(queue.dropGlow.enumerated()), id: \.offset) { index, glow in
                // CSS blurs a shadow over its blur radius; SwiftUI's radius is about half of it.
                shape.fill(Color.black)
                    .padding(max(-glow.spread, 0))
                    .shadow(color: glow.color.color.opacity(queue.dropGlowOpacity[index]), radius: glow.blur / 2, x: glow.x, y: glow.y)
            }
            shape.fill(Color.black).blendMode(.destinationOut)
        }
        .compositingGroup()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

extension View {
    /// Draws this view as the target under a dragged row while `on` (`.slot.drop`, `.mslot.drop`): a 2 pt accent ring
    /// outside `shape` with the accent's glow, on the accent's tint.
    public func dropTarget<S: InsettableShape>(_ on: Bool, in shape: S) -> some View {
        let queue = DesignTokens.HomeQueue.self
        return background {
            if on {
                ZStack {
                    AccentGlow(shape: shape)
                    shape.fill(queue.dropTint.color)
                }
            }
        }
        .overlay {
            if on {
                shape.inset(by: -queue.dropRing / 2)
                    .stroke(queue.dropColor.color, lineWidth: queue.dropRing)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}

// MARK: - Probes, for the tests that read where a part stands

extension EnvironmentValues {
    /// An AppKit view per part: each part carries its view as a background, so a test reads its frame.
    @Entry var queueRowProbes: [QueueRow.Part: NSView] = [:]
}

private struct QueueRowProbe: NSViewRepresentable {
    let view: NSView

    func makeNSView(context _: Context) -> NSView { view }
    func updateNSView(_: NSView, context _: Context) {}
}

extension View {
    @ViewBuilder func probe(_ part: QueueRow.Part, _ probes: [QueueRow.Part: NSView]) -> some View {
        if let view = probes[part] {
            background(QueueRowProbe(view: view))
        } else {
            self
        }
    }
}
