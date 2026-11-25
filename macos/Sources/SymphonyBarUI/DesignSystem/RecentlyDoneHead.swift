import SwiftUI
import SymphonyBarCore

// Recently done's head (TP-1644, `.pq-recent .pq-head` in `docs/design/prototypes/home-queue/`): one line with the
// section's title, the count of the picked range (none at 0), the segmented control at the small size (Today | Week),
// and at the right end the chevron that folds the section to its head. A click anywhere on the head but the control
// folds or opens the section; under the pointer the chevron stands on the pressed surface.

public struct RecentlyDoneHead: View {
    @Binding var range: HomeRead.DoneRange
    let count: String?
    let open: Bool
    let hovered: Bool?
    let toggle: () -> Void
    @State private var pointer = false
    @FocusState private var focused: Bool

    /// The head of a section on `range`, with `count` beside the title (nil draws none), `open` or folded. `hovered`
    /// draws the hover still, for a story; nil follows the pointer.
    public init(
        range: Binding<HomeRead.DoneRange>, count: String?, open: Bool, hovered: Bool? = nil, toggle: @escaping () -> Void
    ) {
        _range = range
        self.count = count
        self.open = open
        self.hovered = hovered
        self.toggle = toggle
    }

    /// The chevron's glyph: down while open, right while folded.
    public static func twistSymbol(open: Bool) -> String { open ? "chevron.down" : "chevron.right" }

    /// What VoiceOver says of the fold.
    public static func foldValue(open: Bool) -> String { open ? "Open" : "Folded" }

    public static let rangeLabel = "Range"

    public var body: some View {
        let queue = DesignTokens.HomeQueue.self
        let hover = hovered ?? pointer
        HStack(spacing: queue.headGap) {
            HStack(alignment: .firstTextBaseline, spacing: queue.headGap) {
                Text(RecentlyDoneList.title)
                    .textStyle(.sentence)
                    .foregroundStyle(DesignTokens.TextColor.primary.color)
                if let count {
                    Text(count)
                        .textStyle(.secondary)
                        .monospacedDigit()
                        .foregroundStyle(DesignTokens.TextColor.secondary.color)
                }
            }
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            .onKeyPress(keys: FoldKeys.keys, phases: .down) { press in
                guard FoldKeys.toggles(press.key, modifiers: press.modifiers) else { return .ignored }
                toggle()
                return .handled
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(count.map { "\(RecentlyDoneList.title), \($0)" } ?? RecentlyDoneList.title)
            .accessibilityValue(Self.foldValue(open: open))
            .accessibilityAddTraits([.isHeader, .isButton])
            .accessibilityAction { toggle() }
            .qaName(QAElementNames.recentlyDoneHead, focused: focused)
            SegmentedControl(
                Self.rangeLabel, selection: $range,
                segments: HomeRead.DoneRange.allCases.map { Segment($0, $0.title) }, size: .small
            )
            .padding(.leading, queue.rangeLead)
            .qaName(QAElementNames.recentlyDoneRange)
            Spacer(minLength: 0)
            let twist = RoundedRectangle(cornerRadius: queue.twistRadius, style: .continuous)
            Image(systemName: Self.twistSymbol(open: open))
                .font(DesignTokens.TypeStyle.font(size: queue.twistGlyph, weight: DesignTokens.TypeStyle.label.weight))
                .foregroundStyle((hover ? DesignTokens.TextColor.primary : DesignTokens.TextColor.secondary).color)
                .frame(width: queue.twistSize, height: queue.twistSize)
                .background { if hover { twist.fill(DesignTokens.StateSurface.pressed.fill) } }
                .focusRing(focused, twist)
                .accessibilityHidden(true)
        }
        .frame(height: queue.headHeight)
        .contentShape(Rectangle())
        .onHover { pointer = $0 }
        .buttonPointer()
        .onTapGesture(perform: toggle)
    }
}
