import SwiftUI
import SymphonyBarCore

// The catalog's Collapsible card and its fold (`docs/design/catalog/stories.js`, the Collapsible card's `render` and
// `fold()`; `.collapsible`, `.fold-head` and `.fold` in `components.css`, TP-1511). A head with the disclosure chevron,
// a title and a summary at the trailing end that fades while the card is open; under it the body, which opens on the
// catalog's fold motion: the height grows on `motion.standard` while its rows fade down into place `motion.stagger`
// apart, and the chevron turns on the fold's spring. Folding plays it backwards, all at once. Under Reduce Motion it
// opens and closes at once. Every measure is `DesignTokens.Collapsible`'s.
//
// `CollapsibleHead` is the head alone, for a fold that is not a card: a run group, a step, a decision or a panel's
// brief fold it in a line (`.line`) in their own lists.

// MARK: - The head

/// A fold's head: the chevron, then the title and, at the trailing end, the summary. It has hover, pressed and
/// keyboard focus, toggles on a click, Return or Space, and reads as a button with its state. `empty` is the card that
/// cannot open: no chevron, "None yet" in the summary's place, no hover and no focus. With `disabledReason` it cannot
/// open either and says why under the pointer.
public struct CollapsibleHead<Title: View>: View {
    /// A card's head (48 pt, the heading style, the card's corners), or a fold's line inside a list (the row's face).
    public enum Style: Equatable {
        case card
        case line
    }

    let expanded: Bool
    let style: Style
    let summary: String?
    let empty: Bool
    let disabledReason: String?
    let accessibilityLabel: String
    let spokenValue: String?
    let drawnAs: DesignTokens.Interaction?
    let toggle: () -> Void
    let title: Title

    @State private var hovered = false
    @State private var pressed = false
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// `accessibilityValue` is read after the label; by default a card's head reads its state and its summary
    /// (`DesignTokens.Collapsible.spokenValue`) and a line reads nothing more (its caller puts the state in the label).
    /// `drawnAs` draws a state still, for the gallery's stories.
    public init(
        expanded: Bool, style: Style = .card, summary: String? = nil, empty: Bool = false, disabledReason: String? = nil,
        accessibilityLabel: String, accessibilityValue: String? = nil, drawnAs: DesignTokens.Interaction? = nil,
        toggle: @escaping () -> Void, @ViewBuilder title: () -> Title
    ) {
        self.expanded = expanded
        self.style = style
        self.summary = summary
        self.empty = empty
        self.disabledReason = disabledReason
        self.accessibilityLabel = accessibilityLabel
        self.spokenValue = accessibilityValue
            ?? (style == .card ? DesignTokens.Collapsible.spokenValue(expanded: expanded, summary: summary, empty: empty) : nil)
        self.drawnAs = drawnAs
        self.toggle = toggle
        self.title = title()
    }

    private var enabled: Bool { disabledReason == nil && !empty }

    /// How far a press may travel and still be a click, in points.
    public static var clickSlop: CGFloat { 4 }

    /// Whether a press that moved by `translation` is a click rather than a drag.
    public static func isClick(_ translation: CGSize) -> Bool {
        abs(translation.width) <= clickSlop && abs(translation.height) <= clickSlop
    }

    private var state: DesignTokens.Interaction {
        drawnAs ?? DesignTokens.Interaction(hovered: hovered && enabled, pressed: pressed && enabled, focused: focused)
    }

    public var body: some View {
        face
            .contentShape(Rectangle())
            .focusable(enabled)
            .focusEffectDisabled()
            .focused($focused)
            .onHover { hovered = $0 }
            // One gesture presses and clicks: a press released where it began toggles. A separate tap here lost the click
            // to the timeline row's own select tap around it, so a click selected the run and never folded it (TP-1480's QA).
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in if !pressed { pressed = true } }
                    .onEnded { value in
                        pressed = false
                        if enabled, Self.isClick(value.translation) { toggle() }
                    }
            )
            .onKeyPress(keys: FoldKeys.keys, phases: .down) { press in
                guard enabled, FoldKeys.toggles(press.key, modifiers: press.modifiers) else { return .ignored }
                toggle()
                return .handled
            }
            .help(disabledReason ?? "")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityValue(spokenValue ?? "")
            .accessibilityHint(disabledReason ?? "")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { if enabled { toggle() } }
    }

    @ViewBuilder private var face: some View {
        switch style {
        case .card:
            let shape = RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous)
            HStack(spacing: DesignTokens.Collapsible.headGap) {
                if !empty { chevron }
                title
                    .textStyle(.heading)
                    .foregroundStyle(empty ? DesignTokens.TextColor.secondary.color : DesignTokens.TextColor.primary.color)
                Spacer(minLength: DesignTokens.Collapsible.headGap)
                if let shown = empty ? Optional(DesignTokens.Collapsible.emptySummary) : summary {
                    Text(shown)
                        .textStyle(.secondary)
                        .foregroundStyle(DesignTokens.TextColor.secondary.color)
                        .monospacedDigit()
                        .lineLimit(1)
                        .opacity(empty ? 1 : DesignTokens.Collapsible.summaryOpacity(expanded: expanded))
                        .animation(.motion(.standard, reduceMotion: reduceMotion), value: expanded)
                }
            }
            .padding(.vertical, DesignTokens.Collapsible.headVerticalPadding)
            .padding(.horizontal, DesignTokens.Collapsible.headHorizontalPadding)
            .frame(maxWidth: .infinity, minHeight: DesignTokens.Collapsible.headMinHeight, alignment: .leading)
            .background {
                if enabled, let surface = state.surface { shape.fill(surface.fill) }
            }
            .focusRing(state.showsFocusRing && enabled, shape)
            .animation(.motion(.fast, reduceMotion: reduceMotion), value: state)
        case .line:
            HStack(spacing: DesignTokens.Space.s2) {
                chevron.frame(width: 12)
                title
                if let summary {
                    Spacer(minLength: DesignTokens.Space.s2)
                    Text(summary)
                        .textStyle(.caption)
                        .foregroundStyle(DesignTokens.TextColor.secondary.color)
                        .monospacedDigit()
                        .fixedSize()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(RowFace(
                state: state,
                reduceMotion: reduceMotion,
                bleed: EdgeInsets(top: DesignTokens.Space.s1, leading: DesignTokens.Space.s2, bottom: DesignTokens.Space.s1, trailing: DesignTokens.Space.s2)
            ))
        }
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: DesignTokens.Collapsible.chevronSize, weight: .semibold))
            .foregroundStyle(enabled ? DesignTokens.TextColor.secondary.color : DesignTokens.TextColor.tertiary.color)
            .rotationEffect(.degrees(DesignTokens.Collapsible.chevronDegrees(expanded: expanded)))
            .animation(.motion(.fold, reduceMotion: reduceMotion), value: expanded)
            .accessibilityHidden(true)
    }
}

// MARK: - The body

/// A fold's body: there while `expanded`, gone while folded. Open it inside `withAnimation(Collapsible.opening)` and
/// its height grows on `motion.standard`; give its rows `.foldRow(_:)` and they fade down into place one after another.
public struct FoldBody<Content: View>: View {
    let expanded: Bool
    let content: Content

    public init(expanded: Bool, @ViewBuilder content: () -> Content) {
        self.expanded = expanded
        self.content = content()
    }

    public var body: some View {
        if expanded {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity)
        }
    }
}

/// The fold's animations, for whoever toggles a fold.
public enum FoldMotion {
    /// The body's height opening and closing: `motion.standard`; at once under Reduce Motion.
    public static func opening(reduceMotion: Bool) -> Animation { .motion(.standard, reduceMotion: reduceMotion) }
}

extension View {
    /// The `index`th row of a fold's body: it fades down into place as the fold opens, `motion.stagger` after the row
    /// above it; there at once under Reduce Motion and in offscreen snapshots.
    public func foldRow(_ index: Int) -> some View { modifier(FoldRowEntering(index: index)) }
}

private struct FoldRowEntering: ViewModifier {
    let index: Int
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.offscreenSnapshot) private var offscreenSnapshot

    func body(content: Content) -> some View {
        let still = reduceMotion || offscreenSnapshot
        let visible = shown || still
        content
            .opacity(visible ? 1 : 0)
            .offset(y: visible ? 0 : -DesignTokens.Collapsible.rowEnterOffset)
            .onAppear {
                guard !still else { return }
                withAnimation(.motion(.standard, reduceMotion: false).delay(DesignTokens.Motion.staggerDelay(index, reduceMotion: false))) {
                    shown = true
                }
            }
    }
}

// MARK: - The card

/// The catalog's Collapsible card: a panel whose head says what is inside (`summary`: a count, a duration) and whose
/// body folds away. `empty` is the card with nothing in it: it cannot open and says "None yet". The fold is the
/// caller's to remember (`expanded`).
public struct CollapsibleCard<Title: View, Content: View>: View {
    @Binding var expanded: Bool
    let summary: String?
    let empty: Bool
    let accessibilityLabel: String
    let drawnAs: DesignTokens.Interaction?
    let title: Title
    let content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// A card titled by `title`, read by VoiceOver as `accessibilityLabel`.
    public init(
        expanded: Binding<Bool>, summary: String?, empty: Bool = false, accessibilityLabel: String,
        drawnAs: DesignTokens.Interaction? = nil, @ViewBuilder title: () -> Title, @ViewBuilder content: () -> Content
    ) {
        _expanded = expanded
        self.summary = summary
        self.empty = empty
        self.accessibilityLabel = accessibilityLabel
        self.drawnAs = drawnAs
        self.title = title()
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CollapsibleHead(
                expanded: expanded && !empty, style: .card, summary: summary, empty: empty,
                accessibilityLabel: accessibilityLabel, drawnAs: drawnAs,
                toggle: { withAnimation(FoldMotion.opening(reduceMotion: reduceMotion)) { expanded.toggle() } }
            ) { title }
            FoldBody(expanded: expanded && !empty) {
                content
                    .padding(.leading, DesignTokens.Collapsible.bodyLeadingPadding)
                    .padding([.trailing, .bottom], DesignTokens.Collapsible.bodyPadding)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelSurface(in: PanelStyle.shape)
        .accessibilityElement(children: .contain)
    }
}

extension CollapsibleCard where Title == Text {
    /// A card titled in words.
    public init(
        _ title: String, summary: String?, expanded: Binding<Bool>, empty: Bool = false, drawnAs: DesignTokens.Interaction? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.init(expanded: expanded, summary: summary, empty: empty, accessibilityLabel: title, drawnAs: drawnAs, title: { Text(title) }, content: content)
    }
}
