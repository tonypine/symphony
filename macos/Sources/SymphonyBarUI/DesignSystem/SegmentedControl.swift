import SwiftUI
import SymphonyBarCore

// C52, the catalog's Segmented control (`.segmented`, `.seg-thumb`, `.segment`; TP-1508).

/// One state of a segmented control, as the live control draws it and the snapshots draw it still: two to five
/// segments sharing the width equally on a sunken capsule track, the selected one under a raised capsule thumb that
/// slides to it, hover and pressed on the others, the focus ring on the selected one, and a disabled form.
public struct SegmentedFace: View {
    let titles: [String]
    /// The selected segment; none draws no thumb (a value the segments don't hold, such as a custom range).
    let selected: Int?
    var size: DesignTokens.Control
    var hovered: Int?
    var pressed: Int?
    var focused: Bool
    var disabled: Bool
    let reduceMotion: Bool

    public init(
        titles: [String], selected: Int?, size: DesignTokens.Control = .medium, hovered: Int? = nil, pressed: Int? = nil,
        focused: Bool = false, disabled: Bool = false, reduceMotion: Bool
    ) {
        self.titles = titles
        self.selected = selected
        self.size = size
        self.hovered = hovered
        self.pressed = pressed
        self.focused = focused
        self.disabled = disabled
        self.reduceMotion = reduceMotion
    }

    public var body: some View {
        let inset = DesignTokens.Segmented.inset
        EqualSegments {
            ForEach(Array(titles.enumerated()), id: \.offset) { index, title in
                segment(index, title)
            }
        }
        .background(alignment: .leading) { thumb }
        .padding(inset)
        .frame(height: size.height)
        .background {
            ZStack {
                Capsule().fill(DesignTokens.Surface.sunken.color)
                Capsule().strokeBorder(DesignTokens.Surface.separator.color, lineWidth: DesignTokens.Control.edgeWidth)
            }
        }
        .animation(.motion(.slide, reduceMotion: reduceMotion), value: selected)
        .animation(.motion(.fast, reduceMotion: reduceMotion), value: hovered)
        .animation(.motion(.fast, reduceMotion: reduceMotion), value: pressed)
    }

    private func segment(_ index: Int, _ title: String) -> some View {
        let isSelected = index == selected
        let surface: DesignTokens.StateSurface? = disabled || isSelected ? nil : index == pressed ? .pressed : index == hovered ? .hover : nil
        return Text(title)
            .font(size.labelFont)
            .lineLimit(1)
            .lineHeight(.multiple(factor: 1))
            .foregroundStyle(foreground(index))
            .padding(.horizontal, size.padding * DesignTokens.Segmented.paddingScale)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { if let surface { Capsule().fill(surface.fill) } }
            .contentShape(Capsule())
    }

    private func foreground(_ index: Int) -> Color {
        if disabled { return DesignTokens.TextColor.tertiary.color }
        return (index == selected || index == hovered || index == pressed ? DesignTokens.TextColor.primary : DesignTokens.TextColor.secondary).color
    }

    @ViewBuilder private var thumb: some View {
        if let selected, !titles.isEmpty {
            GeometryReader { proxy in
                let width = proxy.size.width / CGFloat(titles.count)
                Capsule()
                    .fill((disabled ? DesignTokens.Surface.raised : DesignTokens.Surface.content).color)
                    .overlay {
                        Capsule().strokeBorder(
                            (disabled ? DesignTokens.Surface.separator : DesignTokens.Surface.strong).color,
                            lineWidth: DesignTokens.Segmented.hairline
                        )
                    }
                    .modifier(ThumbDepth(raised: !disabled))
                    .focusRing(focused && !disabled, Capsule())
                    .frame(width: width, height: proxy.size.height)
                    .offset(x: DesignTokens.Segmented.thumbOffset(index: selected, count: titles.count, width: proxy.size.width))
            }
            .accessibilityHidden(true)
        }
    }
}

/// The thumb's depth: the first elevation and the edge highlight, as a raised control's.
private struct ThumbDepth: ViewModifier {
    let raised: Bool

    func body(content: Content) -> some View {
        if raised { content.edgeHighlight(Capsule()).elevation(.level1, in: Capsule()) } else { content }
    }
}

/// Segments that share the width equally: each as wide as the widest needs, or a share of a wider proposal.
struct EqualSegments: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let widest = sizes.map(\.width).max() ?? 0
        let width = max(widest * CGFloat(subviews.count), proposal.width ?? 0)
        let height = proposal.height ?? sizes.map(\.height).max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let width = bounds.width / CGFloat(subviews.count)
        for (index, subview) in subviews.enumerated() {
            subview.place(
                at: CGPoint(x: bounds.minX + CGFloat(index) * width, y: bounds.minY),
                proposal: ProposedViewSize(width: width, height: bounds.height)
            )
        }
    }
}

/// A segment of a segmented control: the value it stands for and its word.
public struct Segment<Value: Hashable>: Hashable {
    public var value: Value
    public var title: String

    public init(_ value: Value, _ title: String) {
        self.value = value
        self.title = title
    }
}

/// The catalog's segmented control: two to five mutually exclusive views of the same thing, a period, a unit, a
/// layout; the choice applies at once. Picking a segment slides the thumb to it on the `slide` spring. With keyboard
/// focus, Left and Right move the selection; VoiceOver reads each segment with its place ("Week, selected, 2 of 3"). While
/// `disabledReason` is set it is off, and the reason shows under it.
public struct SegmentedControl<Value: Hashable>: View {
    let label: String
    @Binding var selection: Value
    let segments: [Segment<Value>]
    var size: DesignTokens.Control
    var disabledReason: String?

    @State private var hovered: Int?
    @State private var pressed: Int?
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// `label` names the choice for VoiceOver ("Period"); the bar shows it beside the control when it needs a word.
    public init(
        _ label: String, selection: Binding<Value>, segments: [Segment<Value>], size: DesignTokens.Control = .medium,
        disabledReason: String? = nil
    ) {
        precondition(segments.count >= DesignTokens.Segmented.fewest && segments.count <= DesignTokens.Segmented.most,
                     "A segmented control has two to five segments: past five, use a pop-up")
        self.label = label
        _selection = selection
        self.segments = segments
        self.size = size
        self.disabledReason = disabledReason
    }

    private var selectedIndex: Int? { segments.firstIndex { $0.value == selection } }
    private var disabled: Bool { disabledReason != nil }

    public var body: some View {
        SegmentedFace(
            titles: segments.map(\.title), selected: selectedIndex, size: size, hovered: hovered, pressed: pressed,
            focused: focused, disabled: disabled, reduceMotion: reduceMotion
        )
        .overlay { targets }
        .fixedSize()
        .focusable(!disabled)
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.leftArrow) { step(-1) }
        .onKeyPress(.rightArrow) { step(1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
        .disabledReason(disabledReason)
    }

    /// The segments' hit areas over the face: hover, the press and the pick.
    private var targets: some View {
        EqualSegments {
            ForEach(Array(segments.enumerated()), id: \.offset) { index, _ in
                Color.clear
                    .contentShape(Capsule())
                    .accessibilityElement()
                    .accessibilityLabel(segments[index].title)
                    .accessibilityValue("\(index + 1) of \(segments.count)")
                    .accessibilityAddTraits(index == selectedIndex ? [.isButton, .isSelected] : .isButton)
                    .accessibilityAction { if !disabled { pick(index) } }
                    .onHover { inside in
                        if inside { hovered = index } else if hovered == index { hovered = nil }
                    }
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { _ in if !disabled { pressed = index } }
                            .onEnded { value in
                                pressed = nil
                                if !disabled, abs(value.translation.width) < size.height, abs(value.translation.height) < size.height {
                                    pick(index)
                                }
                            }
                    )
            }
        }
        .padding(DesignTokens.Segmented.inset)
    }

    private func pick(_ index: Int) {
        guard segments.indices.contains(index) else { return }
        selection = segments[index].value
    }

    /// Left and Right: the next segment that way, stopping at the ends.
    private func step(_ by: Int) -> KeyPress.Result {
        guard !disabled else { return .ignored }
        let from = selectedIndex ?? (by > 0 ? -1 : segments.count)
        let to = min(max(from + by, 0), segments.count - 1)
        if to != selectedIndex { pick(to) }
        return .handled
    }
}
