import AppKit
import SwiftUI
import SymphonyBarCore

// The catalog's shared states (`docs/design/director-ticket-page.md` §4, the catalog's Button, Row and Card stories)
// as SwiftUI styles: hover, pressed, selected, keyboard focus and disabled with its reason, for a row, a card and a
// button. Each style has a face that draws one `DesignTokens.Interaction` (what the snapshots render) and a live
// wrapper that tracks the pointer, the press and the focus and hands the face its state.

// MARK: - Focus ring

extension View {
    /// The focus ring (§3.10) `offset` outside `shape`, following its corners. Draw it for keyboard focus only.
    public func focusRing<S: InsettableShape>(_ shown: Bool, _ shape: S, offset: Double = DesignTokens.FocusRing.offset) -> some View {
        modifier(FocusRingModifier(shown: shown, shape: shape, offset: offset))
    }
}

private struct FocusRingModifier<S: InsettableShape>: ViewModifier {
    let shown: Bool
    let shape: S
    let offset: Double

    func body(content: Content) -> some View {
        content.overlay {
            if shown {
                let width = DesignTokens.FocusRing.width
                shape
                    .inset(by: -(offset + width / 2))
                    .stroke(
                        DesignTokens.FocusRing.color.color,
                        lineWidth: width
                    )
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}

// MARK: - Row

/// A row's face: its state's surface over whatever is under it, the accent ring when selected, the focus ring on
/// its edge. The surface bleeds `bleed` past the row's content, so the content keeps its place in the list.
public struct RowFace: ViewModifier {
    let state: DesignTokens.Interaction
    let reduceMotion: Bool
    var bleed = EdgeInsets(
        top: DesignTokens.Space.s1, leading: DesignTokens.Space.s2,
        bottom: DesignTokens.Space.s1, trailing: DesignTokens.Space.s2
    )

    public init(state: DesignTokens.Interaction, reduceMotion: Bool, bleed: EdgeInsets? = nil) {
        self.state = state
        self.reduceMotion = reduceMotion
        if let bleed { self.bleed = bleed }
    }

    public func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: DesignTokens.Radius.row, style: .continuous)
        content
            .padding(bleed)
            .background {
                if let surface = state.surface {
                    shape.fill(surface.fill)
                }
            }
            .overlay {
                if state.showsSelectionRing {
                    shape.strokeBorder(DesignTokens.Selection.color.color, lineWidth: DesignTokens.Selection.rowRingWidth)
                }
            }
            .focusRing(state.showsFocusRing, shape, offset: 0)
            .padding(EdgeInsets(top: -bleed.top, leading: -bleed.leading, bottom: -bleed.bottom, trailing: -bleed.trailing))
            .scaleEffect(DesignTokens.Motion.scale(DesignTokens.Motion.rowPressScale, pressed: state.pressed, reduceMotion: reduceMotion))
            .animation(.motion(.fast, reduceMotion: reduceMotion), value: state)
    }
}

/// The live row: it tracks the pointer, the press and keyboard focus, and takes focus from the keyboard.
private struct RowStyle: ViewModifier {
    let selected: Bool
    @State private var hovered = false
    @State private var pressed = false
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content
            .modifier(RowFace(
                state: DesignTokens.Interaction(hovered: hovered, pressed: pressed, selected: selected, focused: focused, disabled: !isEnabled),
                reduceMotion: reduceMotion
            ))
            .contentShape(Rectangle())
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            .onHover { hovered = $0 }
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in pressed = true }
                    .onEnded { _ in pressed = false }
            )
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Card

/// A clickable card's face: it lifts a point with a deeper shadow under the pointer, settles to 99 % when pressed,
/// and carries the accent ring when selected and the focus ring outside its corners.
public struct CardFace: ViewModifier {
    let state: DesignTokens.Interaction
    let reduceMotion: Bool

    public init(state: DesignTokens.Interaction, reduceMotion: Bool) {
        self.state = state
        self.reduceMotion = reduceMotion
    }

    public func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous)
        let raised = state.hovered && !state.pressed && !state.disabled
        content
            .overlay {
                if state.showsSelectionRing {
                    shape.strokeBorder(DesignTokens.Selection.color.color, lineWidth: DesignTokens.Selection.cardRingWidth)
                }
            }
            .shadow(color: Color(nsColor: .shadowColor).opacity(raised ? 0.16 : 0.06), radius: raised ? 10 : 2, y: raised ? 5 : 1)
            .focusRing(state.showsFocusRing, shape)
            .scaleEffect(DesignTokens.Motion.scale(DesignTokens.Motion.cardPressScale, pressed: state.pressed, reduceMotion: reduceMotion))
            .offset(y: -DesignTokens.Motion.lift(hovered: raised, reduceMotion: reduceMotion))
            .animation(.motion(.lift, reduceMotion: reduceMotion), value: state)
    }
}

/// The live clickable card.
private struct CardStyle: ViewModifier {
    let selected: Bool
    @State private var hovered = false
    @State private var pressed = false
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content
            .modifier(CardFace(
                state: DesignTokens.Interaction(hovered: hovered, pressed: pressed, selected: selected, focused: focused, disabled: !isEnabled),
                reduceMotion: reduceMotion
            ))
            .contentShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous))
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            .onHover { hovered = $0 }
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in pressed = true }
                    .onEnded { _ in pressed = false }
            )
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

extension View {
    /// A list row's states: the hover and pressed surfaces, the accent tint and ring when `selected`, and the focus
    /// ring for keyboard focus.
    public func rowStyle(selected: Bool = false) -> some View { modifier(RowStyle(selected: selected)) }

    /// A clickable card's states: the lift under the pointer, the press, the accent ring when `selected`, the focus
    /// ring for keyboard focus.
    public func cardStyle(selected: Bool = false) -> some View { modifier(CardStyle(selected: selected)) }
}

// MARK: - Button

/// A button's kind: primary (the accent fill, one per view), secondary (content with a hairline edge) or quiet
/// (accent text, no fill until the pointer is over it).
public enum ButtonKind: String, CaseIterable { case primary, secondary, quiet }

/// A button's face of a kind, at one of the three control sizes.
public struct ButtonFace<Label: View>: View {
    let label: Label
    var kind: ButtonKind = .secondary
    var size: DesignTokens.Control = .medium
    let state: DesignTokens.Interaction
    let reduceMotion: Bool

    public init(label: Label, kind: ButtonKind = .secondary, size: DesignTokens.Control = .medium, state: DesignTokens.Interaction, reduceMotion: Bool) {
        self.label = label
        self.kind = kind
        self.size = size
        self.state = state
        self.reduceMotion = reduceMotion
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: size.radius, style: .continuous)
        label
            .font(.system(size: size.fontSize, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, size.padding)
            .frame(height: size.height)
            .foregroundStyle(foreground)
            .background { background(shape) }
            .overlay {
                if let edge {
                    shape.strokeBorder(edge, lineWidth: 1)
                }
            }
            .focusRing(state.showsFocusRing, shape)
            .scaleEffect(DesignTokens.Motion.scale(DesignTokens.Motion.pressScale, pressed: state.pressed, reduceMotion: reduceMotion))
            .animation(.motion(.instant, reduceMotion: reduceMotion), value: state)
    }


    /// A selected button (its menu or sheet open) stays pressed.
    private var surface: DesignTokens.StateSurface? {
        state.surface == .selected ? .pressed : state.surface
    }

    private var foreground: Color {
        if state.disabled { return DesignTokens.TextColor.tertiary.color }
        return switch kind {
        case .primary: Color(nsColor: .alternateSelectedControlTextColor)
        case .secondary: DesignTokens.TextColor.primary.color
        case .quiet: DesignTokens.ColorToken.accent.color
        }
    }

    private var edge: Color? {
        if kind == .quiet { return nil }
        if state.disabled || kind == .secondary { return DesignTokens.Surface.separator.color }
        return nil
    }

    @ViewBuilder private func background(_ shape: RoundedRectangle) -> some View {
        if state.disabled {
            if kind != .quiet { shape.fill(DesignTokens.Surface.raised.color) }
        } else {
            switch kind {
            case .primary:
                // The accent brightens under the pointer and darkens when pressed.
                shape.fill(DesignTokens.ColorToken.accent.color)
                    .brightness(surface == .pressed ? -0.08 : surface == .hover ? 0.06 : 0)
            case .secondary:
                ZStack {
                    shape.fill(DesignTokens.Surface.content.color)
                    if surface != nil { shape.fill(DesignTokens.Surface.raised.color) }
                    if let surface { shape.fill(surface.fill) }
                }
            case .quiet:
                if let surface { shape.fill(surface.fill) }
            }
        }
    }
}

/// The catalog's button as a `ButtonStyle`: the face, given the press, the pointer, keyboard focus and whether the
/// button is enabled. Pair it with `focusEffectDisabled()`, as `directorButton` does, so only the face's ring shows.
public struct DirectorButtonStyle: ButtonStyle {
    var kind: ButtonKind = .secondary
    var size: DesignTokens.Control = .medium
    var selected = false

    public init(kind: ButtonKind = .secondary, size: DesignTokens.Control = .medium, selected: Bool = false) {
        self.kind = kind
        self.size = size
        self.selected = selected
    }

    public func makeBody(configuration: Configuration) -> some View {
        Face(configuration: configuration, kind: kind, size: size, selected: selected)
    }

    private struct Face: View {
        let configuration: Configuration
        let kind: ButtonKind
        let size: DesignTokens.Control
        let selected: Bool
        @State private var hovered = false
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.isFocused) private var isFocused
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            ButtonFace(
                label: configuration.label,
                kind: kind,
                size: size,
                state: DesignTokens.Interaction(
                    hovered: hovered, pressed: configuration.isPressed, selected: selected, focused: isFocused, disabled: !isEnabled
                ),
                reduceMotion: reduceMotion
            )
            .contentShape(RoundedRectangle(cornerRadius: size.radius, style: .continuous))
            .onHover { hovered = $0 }
        }
    }
}

extension View {
    /// The catalog's button style at `size`; `selected` keeps it pressed while its menu or sheet is open.
    public func directorButton(_ kind: ButtonKind = .secondary, size: DesignTokens.Control = .medium, selected: Bool = false) -> some View {
        buttonStyle(DirectorButtonStyle(kind: kind, size: size, selected: selected)).focusEffectDisabled()
    }
}

// MARK: - Disabled with its reason

/// The reason a control is off, under it: a lock and the sentence (the catalog's inline refusal).
public struct Refusal: View {
    let reason: String

    public init(reason: String) { self.reason = reason }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "lock.fill")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text(reason)
                .font(DesignTokens.TypeStyle.secondary.font)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A control that is off for `reason`: it draws disabled, its help and VoiceOver hint say why, and pressing it
/// shows the reason under it. No reason: the control as it is.
private struct DisabledReason: ViewModifier {
    let reason: String?
    @State private var shown: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(reason: String?, revealed: Bool) {
        self.reason = reason
        _shown = State(initialValue: revealed)
    }

    func body(content: Content) -> some View {
        if let reason {
            VStack(alignment: .leading, spacing: 6) {
                content
                    .disabled(true)
                    .overlay {
                        // A disabled control takes no click: this catches it and shows why.
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture {
                                withAnimation(.motion(.standard, reduceMotion: reduceMotion)) { shown = true }
                            }
                            .accessibilityHidden(true)
                    }
                    .help(reason)
                    .accessibilityHint(reason)
                if shown {
                    Refusal(reason: reason).transition(.opacity)
                }
            }
            .onChange(of: reason) { shown = false }
        } else {
            content
        }
    }
}

extension View {
    /// Disables the control while `reason` is set, and shows the reason under it once pressed (or at once when
    /// `revealed`).
    public func disabledReason(_ reason: String?, revealed: Bool = false) -> some View {
        modifier(DisabledReason(reason: reason, revealed: revealed))
    }
}

// MARK: - Situation kinds

extension DesignTokens.SituationKind {
    /// The kind's status color.
    public var tint: Color { status.tint }

    /// The glyph in its status color.
    public var glyph: some View {
        Image(systemName: symbol).foregroundStyle(tint).accessibilityHidden(true)
    }
}
