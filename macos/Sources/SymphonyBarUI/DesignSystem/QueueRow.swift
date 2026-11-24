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

    /// An epic's row (TP-1645): its sub-tickets done of all, whether its open sub-tickets show (its chevron) and whether
    /// its done ones do (its done count pressed).
    public struct Epic: Equatable {
        public var done: Int
        public var total: Int
        public var open: Bool
        public var showingDone: Bool

        public init(done: Int, total: Int, open: Bool = true, showingDone: Bool = false) {
            self.done = done
            self.total = total
            self.open = open
            self.showingDone = showingDone
        }
    }

    public var id: String { identifier }
    /// Its place in the queue, from 1.
    public var number: Int
    public var identifier: String
    public var title: String
    /// The state glyph: the working dot, a pause, a clock, the person. An epic's row draws its chevron there.
    public var lead: RowLead
    /// The tickets it waits for, one marker each (TP-1645); a met dependency has none.
    public var dependencies: [DependencyMarkerModel]
    /// Its badges: what waits on the person, its state ("Code Review", "Stopped in Coding").
    public var marks: [Mark]
    public var repo: String
    /// The number as the read writes it when it is not a whole one: a sub-ticket's "6.1"; nil draws `number`.
    public var label: String?
    /// An epic's fold and done count; nil for a ticket with no sub-tickets.
    public var epic: Epic?
    /// How many steps in it sits: 0 at the top level, 1 for an epic's sub-ticket.
    public var depth: Int

    /// The number the row shows: "1,243", or a sub-ticket's "6.1".
    public var numberText: String { label ?? DesignTokens.HomeQueue.number(number) }

    public init(
        number: Int, identifier: String, title: String, lead: RowLead, dependencies: [DependencyMarkerModel] = [], marks: [Mark] = [],
        repo: String, label: String? = nil, epic: Epic? = nil, depth: Int = 0
    ) {
        self.label = label
        self.number = number
        self.identifier = identifier
        self.title = title
        self.lead = lead
        self.dependencies = dependencies
        self.marks = marks
        self.repo = repo
        self.epic = epic
        self.depth = depth
    }
}

public struct QueueRow: View {
    /// How a row is drawn: at rest, under the pointer, or dragged.
    public enum Look: String, CaseIterable, Equatable {
        case rest, hover, dragged
    }

    /// The row's parts, each in its own cell.
    public enum Part: String, CaseIterable, Hashable {
        case number, handle, elbow, lead, identifier, title, doneCount, dependencies, marks, repo, start
    }

    let row: QueueRowModel
    let numberWidth: CGFloat
    let fractionWidth: CGFloat
    let look: Look?
    let reorderable: Bool
    let picked: Bool
    let doneCountHovered: Bool?
    let onStart: () -> Void
    let onToggle: () -> Void
    let onToggleDone: () -> Void
    @State private var hovered = false
    @Environment(\.queueRowProbes) private var probes

    /// The row of `row`, its whole number centred in a column `numberWidth` wide (`numberWidth(widest:)` of the numbers
    /// on screen) and the part after a sub-ticket's point in a column `fractionWidth` wide after it
    /// (`fractionWidth(characters:)`, 0 while no sub-row is on screen). `look` draws one look still, for a story; nil
    /// follows the pointer. A row that may not be `reorderable` (a saved view is picked) keeps its number under the
    /// pointer and shows no handle. A `picked` row is the one being dragged, left behind in its place and dimmed
    /// (`.row.dragging`). An epic's row calls `onToggle` on a click, and `onToggleDone` on its done count
    /// (`doneCountHovered` draws its hover still, for a story).
    public init(
        _ row: QueueRowModel, numberWidth: CGFloat, fractionWidth: CGFloat = 0, look: Look? = nil, reorderable: Bool = true,
        picked: Bool = false, doneCountHovered: Bool? = nil, onStart: @escaping () -> Void = {}, onToggle: @escaping () -> Void = {},
        onToggleDone: @escaping () -> Void = {}
    ) {
        self.row = row
        self.numberWidth = numberWidth
        self.fractionWidth = fractionWidth
        self.look = look
        self.reorderable = reorderable
        self.picked = picked
        self.doneCountHovered = doneCountHovered
        self.onStart = onStart
        self.onToggle = onToggle
        self.onToggleDone = onToggleDone
    }

    /// The width of `text` in the number's style, its figures tabular.
    static func figuresWidth(_ text: String) -> CGFloat {
        let font = NSFont.monospacedDigitSystemFont(
            ofSize: DesignTokens.TypeStyle.secondary.nsFont.pointSize,
            weight: NSFont.Weight(rawValue: CGFloat(DesignTokens.TypeStyle.secondary.systemWeight))
        )
        return ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    /// The width the part after a sub-ticket's point adds to the number cell, for `characters` of it on screen ("6.12"
    /// has 3); 0 for none, so the cell widens only while sub-rows are on screen.
    public static func fractionWidth(characters: Int) -> CGFloat {
        characters > 0 ? figuresWidth(DesignTokens.HomeQueue.fractionTemplate(characters: characters)) : 0
    }

    /// The number cell's width for the widest number on screen: its digits in the secondary style's tabular figures,
    /// at least two.
    public static func numberWidth(widest: Int) -> CGFloat {
        figuresWidth(DesignTokens.HomeQueue.numberTemplate(widest: widest))
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
            if row.depth > 0 {
                if row.depth > 1 { Color.clear.frame(width: queue.subRowStep * Double(row.depth - 1) - queue.rowPartGap) }
                QueueElbow().probe(.elbow, probes)
            }
            Group {
                if let epic = row.epic {
                    QueueEpicChevron(open: epic.open)
                } else {
                    RowLeadMark(lead: row.lead)
                        .frame(width: DesignTokens.Row.leadSize, height: DesignTokens.Row.leadSize)
                        .padding(.horizontal, queue.leadMargin)
                }
            }
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
        .modifier(EpicToggle(epic: row.epic != nil, toggle: onToggle))
        .accessibilityElement(children: .combine)
        // The label also says it is dragged: a combined element's value does not always reach the tree mid-drag.
        .accessibilityLabel(Self.accessibilityLabel(row, picked: picked))
        .accessibilityValue(Self.accessibilityState(look, reorderable: reorderable, picked: picked))
        .accessibilityIdentifier(Self.accessibilityIdentifier(row.identifier))
        .accessibilityAction(named: "Start") { onStart() }
        .modifier(EpicActions(epic: row.epic, toggle: onToggle, toggleDone: onToggleDone))
    }

    /// The row's label: its number, identifier and title, an epic's fold and done count, the tickets it waits for, and,
    /// while it is the row left behind under a drag, `Dragged`.
    public static func accessibilityLabel(_ row: QueueRowModel, picked: Bool) -> String {
        var parts = ["Number \(row.numberText)", row.identifier, row.title]
        if let epic = row.epic {
            parts.append(epic.open ? "open" : "closed")
            parts.append(DesignTokens.HomeQueue.doneCount(done: epic.done, total: epic.total))
        }
        parts += row.dependencies.map(\.accessibilityLabel)
        if picked { parts.append(draggedValue) }
        return parts.joined(separator: ", ")
    }

    /// An epic's actions, as VoiceOver names them.
    public static func toggleTitle(open: Bool) -> String { open ? "Hide sub-tickets" : "Show sub-tickets" }
    public static func toggleDoneTitle(showing: Bool) -> String { showing ? "Hide done sub-tickets" : "Show done sub-tickets" }

    /// The row's identifier in the accessibility tree, which a window test finds it by.
    public static func accessibilityIdentifier(_ ticket: String) -> String { "queue-row-\(ticket)" }

    /// The row's state as the accessibility tree says it (TP-1610): `Dragged` while it is the row left behind under a
    /// drag, `Drag handle` while the handle stands in the number's place, nothing at rest.
    public static func accessibilityState(_ look: Look, reorderable: Bool, picked: Bool) -> String {
        if picked { return draggedValue }
        return handles(look, reorderable: reorderable) ? handleValue : ""
    }

    public static let draggedValue = "Dragged"
    public static let handleValue = "Drag handle"

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
            QueueNumberText(text: row.numberText, whole: numberWidth, fraction: fractionWidth)
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
        .frame(width: numberWidth + fractionWidth, height: queue.numberHeight)
    }

    /// An epic's done count, the tickets it waits for, its badges, then the repo, and Start in the repo's cell under the
    /// pointer.
    private func trail(_ look: Look) -> some View {
        let queue = DesignTokens.HomeQueue.self
        let starts = Self.starts(look)
        return HStack(spacing: queue.rowMainGap) {
            if let epic = row.epic {
                QueueDoneCount(done: epic.done, total: epic.total, pressed: epic.showingDone, hovered: doneCountHovered, toggle: onToggleDone)
                    .probe(.doneCount, probes)
            }
            if !row.dependencies.isEmpty {
                HStack(spacing: queue.rowMainGap) {
                    ForEach(row.dependencies) { DependencyMarker($0) }
                }
                .fixedSize()
                .probe(.dependencies, probes)
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

/// A click on an epic's row opens and closes it (TP-1645); any other row takes no click.
private struct EpicToggle: ViewModifier {
    let epic: Bool
    let toggle: () -> Void

    func body(content: Content) -> some View {
        if epic {
            content.onTapGesture(perform: toggle)
        } else {
            content
        }
    }
}

/// An epic's row's actions for VoiceOver: show or hide its sub-tickets, and its done ones.
private struct EpicActions: ViewModifier {
    let epic: QueueRowModel.Epic?
    let toggle: () -> Void
    let toggleDone: () -> Void

    func body(content: Content) -> some View {
        if let epic {
            content
                .accessibilityAction(named: Text(QueueRow.toggleTitle(open: epic.open)), toggle)
                .accessibilityAction(named: Text(QueueRow.toggleDoneTitle(showing: epic.showingDone)), toggleDone)
        } else {
            content
        }
    }
}

/// The line in the gap a dragged row lands in (`.drop-line`): 2 pt of the accent with its glow, inset by the row's room at
/// both ends, in the 2 pt between the row above and the one below. A sub-row's line (`.drop-line.sub`) starts `indent`
/// further in, at the sub-row's step (`indent(numberCell:)`).
public struct QueueDropLine: View {
    let indent: CGFloat

    public init(indent: CGFloat = 0) {
        self.indent = indent
    }

    /// Where a sub-row's drop line starts after the row's room: past the number cell `numberCell` wide and the elbow's
    /// step, where the sub-row's state glyph starts.
    public static func indent(numberCell: CGFloat) -> CGFloat {
        numberCell + DesignTokens.HomeQueue.rowPartGap + DesignTokens.HomeQueue.subRowStep
    }

    public var body: some View {
        let queue = DesignTokens.HomeQueue.self
        let shape = RoundedRectangle(cornerRadius: queue.dropLineRadius, style: .continuous)
        shape.fill(queue.dropColor.color)
            .frame(height: queue.dropLineHeight)
            .background { AccentGlow(shape: shape) }
            .padding(.leading, indent)
            .padding(.horizontal, queue.rowInset)
            .allowsHitTesting(false)
            .accessibilityElement()
            .accessibilityLabel(Self.accessibilityLabel)
            .accessibilityIdentifier(Self.accessibilityIdentifier)
    }

    /// The line in the accessibility tree (TP-1610): where a drop would land, which a window test reads mid-drag.
    public static let accessibilityLabel = "Drop here"
    public static let accessibilityIdentifier = "queue-drop-line"
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
        dropTargetLook(on, in: shape)
    }

    /// The accessibility tree's word for a slot under a dragged row (TP-1610), and the element's `identifier`, which a
    /// window test finds the card or the strip line by. Call it after the element is made.
    public func dropTargetAccessibility(_ on: Bool, identifier: String) -> some View {
        accessibilityValue(on ? SlotDropTarget.accessibilityValue : "")
            .accessibilityIdentifier(identifier)
    }

    private func dropTargetLook<S: InsettableShape>(_ on: Bool, in shape: S) -> some View {
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

/// A slot drawn as the target under a dragged row: what the accessibility tree says of it.
public enum SlotDropTarget {
    public static let accessibilityValue = "Drop target"
    /// A slot's label `label`, which also says it is the target while `on`: a card holds its parts and a strip line
    /// combines them, and neither element's value reaches the tree mid-drag.
    public static func accessibilityLabel(_ label: String, on: Bool) -> String { on ? "\(label), \(accessibilityValue)" : label }
    /// The identifier of slot `slot`'s card, or of its line in the strip.
    public static func cardIdentifier(_ slot: Int) -> String { "slot-card-\(slot)" }
    public static func lineIdentifier(_ slot: Int) -> String { "slot-line-\(slot)" }
}
