import SwiftUI
import SymphonyBarCore

// An epic in the Home queue (TP-1645, `docs/design/prototypes/home-queue/` section Queue, `shots/queue-epic-2x.png`):
// the epic's row has a chevron in the state glyph's cell and its done count ("2 of 11 done") as a control before the
// repo; a sub-ticket's row sits one step in, the step filled by an elbow under the epic's chevron, and is numbered inside
// its epic ("6.1"), the whole numbers in one column and the part after the point hanging to their right.

/// The elbow that fills a sub-row's step (`.elbow`): a rounded corner, down then right, in the tertiary text colour.
public struct QueueElbow: View {
    public init() {}

    public var body: some View {
        let queue = DesignTokens.HomeQueue.self
        QueueElbowShape()
            .stroke(queue.elbowColor.color, style: StrokeStyle(lineWidth: queue.elbowStroke * queue.elbowGlyph / queue.elbowGrid, lineCap: .round, lineJoin: .round))
            .frame(width: queue.elbowGlyph, height: queue.elbowGlyph)
            .frame(width: DesignTokens.Row.leadSize, height: DesignTokens.Row.leadSize)
            .padding(.horizontal, queue.leadMargin)
            .accessibilityHidden(true)
    }
}

/// The elbow's line on the prototype's 16-unit grid (`M8 0.5v5a2.5 2.5 0 0 0 2.5 2.5h5`), scaled to the rect.
struct QueueElbowShape: Shape {
    func path(in rect: CGRect) -> Path {
        let unit = min(rect.width, rect.height) / DesignTokens.HomeQueue.elbowGrid
        func point(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: rect.minX + x * unit, y: rect.minY + y * unit) }
        var path = Path()
        path.move(to: point(8, 0.5))
        path.addLine(to: point(8, 5.5))
        path.addArc(tangent1End: point(8, 8), tangent2End: point(10.5, 8), radius: 2.5 * unit)
        path.addLine(to: point(15.5, 8))
        return path
    }
}

/// The epic's chevron in the state glyph's cell: down while its sub-tickets show, right while it is closed.
public struct QueueEpicChevron: View {
    let open: Bool

    public init(open: Bool) {
        self.open = open
    }

    public static func symbol(open: Bool) -> String { RecentlyDoneHead.twistSymbol(open: open) }

    public var body: some View {
        let queue = DesignTokens.HomeQueue.self
        Image(systemName: Self.symbol(open: open))
            .font(DesignTokens.TypeStyle.font(size: queue.chevronGlyph, weight: DesignTokens.TypeStyle.label.weight))
            .foregroundStyle(DesignTokens.TextColor.secondary.color)
            .frame(width: DesignTokens.Row.leadSize, height: DesignTokens.Row.leadSize)
            .padding(.horizontal, queue.leadMargin)
            .accessibilityHidden(true)
    }
}

/// The epic's done count (`.q-done`): "2 of 11 done" in quiet text, a control that shows and hides the epic's done
/// sub-tickets. Pressed while they show, and under the pointer, it stands on the pressed surface in the secondary colour.
public struct QueueDoneCount: View {
    let done: Int
    let total: Int
    let pressed: Bool
    let hovered: Bool?
    let toggle: () -> Void
    @State private var pointer = false

    /// The count of `done` of `total`, `pressed` while the done rows show. `hovered` draws the hover still, for a story;
    /// nil follows the pointer.
    public init(done: Int, total: Int, pressed: Bool, hovered: Bool? = nil, toggle: @escaping () -> Void = {}) {
        self.done = done
        self.total = total
        self.pressed = pressed
        self.hovered = hovered
        self.toggle = toggle
    }

    /// Whether it stands on the pressed surface: while pressed, and under the pointer.
    public static func lifted(pressed: Bool, hovered: Bool) -> Bool { pressed || hovered }

    public var body: some View {
        let queue = DesignTokens.HomeQueue.self
        let shape = RoundedRectangle(cornerRadius: queue.doneCountRadius, style: .continuous)
        let lifted = Self.lifted(pressed: pressed, hovered: hovered ?? pointer)
        Text(DesignTokens.HomeQueue.doneCount(done: done, total: total))
            .textStyle(.secondary)
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle((lifted ? DesignTokens.TextColor.secondary : DesignTokens.TextColor.tertiary).color)
            .padding(.horizontal, queue.doneCountInsetX)
            .padding(.vertical, queue.doneCountInsetY)
            .background { if lifted { shape.fill(DesignTokens.StateSurface.pressed.fill) } }
            .padding(.horizontal, -queue.doneCountInsetX)
            .contentShape(shape)
            .onHover { pointer = $0 }
            .buttonPointer()
            .onTapGesture(perform: toggle)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(DesignTokens.HomeQueue.doneCount(done: done, total: total))
            .accessibilityValue(pressed ? "Shown" : "Hidden")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { toggle() }
            .qaName(QAElementNames.queueDoneCount)
    }
}

/// A queue number in its cell: the whole number centred in a column `whole` wide, and the part after the point
/// ("." and the sub-ticket's place) hanging right after its digits, in a column `fraction` wide.
struct QueueNumberText: View {
    let text: String
    let whole: CGFloat
    let fraction: CGFloat

    /// The whole number and the part after the first point: "6" and ".1" for "6.1", "1,243" and "" for "1,243".
    static func split(_ text: String) -> (whole: String, fraction: String) {
        guard let dot = text.firstIndex(of: ".") else { return (text, "") }
        return (String(text[..<dot]), String(text[dot...]))
    }

    var body: some View {
        let parts = Self.split(text)
        ZStack(alignment: .leading) {
            Text(parts.whole)
                .textStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
                .frame(width: whole)
            if !parts.fraction.isEmpty {
                Text(parts.fraction)
                    .textStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
                    .offset(x: (whole + QueueRow.figuresWidth(parts.whole)) / 2)
            }
        }
        .frame(width: whole + fraction, alignment: .leading)
    }
}
