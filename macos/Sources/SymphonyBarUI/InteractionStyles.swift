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

/// A button's kind (the catalog's Button): primary (the accent fill, the one move we expect in a place), secondary
/// (content with a hairline edge, every other move), quiet (accent text, no fill until the pointer is over it),
/// destructive (problem text on the secondary face, for what stops or throws work away) and destructive filled (the
/// problem fill, the confirming button of a sheet that stops or throws work away).
public enum ButtonKind: String, CaseIterable {
    case primary, secondary, quiet, destructive
    case destructiveFilled = "destructive-filled"
}

extension DesignTokens.Control {
    /// A control label's font: the size's label size at the catalog's 550 weight, under the system's text size.
    public var labelFont: Font {
        let scale = DesignTokens.TypeStyle.textScale
        return Font(NSFont.systemFont(ofSize: CGFloat(fontSize * scale), weight: NSFont.Weight(rawValue: CGFloat(DesignTokens.TypeStyle.label.systemWeight))) as CTFont)
    }

    /// A glyph's font at the size's glyph size: `glyphSize` in a button, `iconGlyphSize` in an icon button.
    public func glyphFont(icon: Bool = false) -> Font {
        let scale = DesignTokens.TypeStyle.textScale
        return Font(NSFont.systemFont(ofSize: CGFloat((icon ? iconGlyphSize : glyphSize) * scale), weight: NSFont.Weight(rawValue: CGFloat(DesignTokens.TypeStyle.label.systemWeight))) as CTFont)
    }
}

/// A button's face of a kind, at one of the three control sizes, with an optional leading SF Symbol: one state of it,
/// as `DirectorButtonStyle` draws it live and the snapshots draw it still.
public struct ButtonFace<Label: View>: View {
    let label: Label
    var kind: ButtonKind = .secondary
    var size: DesignTokens.Control = .medium
    var glyph: String?
    let state: DesignTokens.Interaction
    let reduceMotion: Bool

    public init(
        label: Label, kind: ButtonKind = .secondary, size: DesignTokens.Control = .medium, glyph: String? = nil,
        state: DesignTokens.Interaction, reduceMotion: Bool
    ) {
        self.label = label
        self.kind = kind
        self.size = size
        self.glyph = glyph
        self.state = state
        self.reduceMotion = reduceMotion
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: size.radius, style: .continuous)
        HStack(spacing: DesignTokens.Control.glyphGap) {
            if let glyph {
                Image(systemName: glyph).font(size.glyphFont()).accessibilityHidden(true)
            }
            label.font(size.labelFont).lineLimit(1)
        }
        // A label's line is its own, whatever text style the view around it set.
        .lineHeight(.multiple(factor: 1))
        .padding(.horizontal, size.padding)
        .frame(height: size.height)
        .foregroundStyle(foreground)
        .background { background(shape) }
        .overlay {
            if let edge { shape.strokeBorder(edge, lineWidth: DesignTokens.Control.edgeWidth) }
        }
        .modifier(ButtonDepth(raised: raised, shape: shape))
        .focusRing(state.showsFocusRing, shape)
        .scaleEffect(DesignTokens.Motion.scale(DesignTokens.Motion.pressScale, pressed: pressed, reduceMotion: reduceMotion))
        .animation(.motion(.instant, reduceMotion: reduceMotion), value: state)
    }

    /// A selected button (its menu or sheet open) stays pressed.
    private var surface: DesignTokens.StateSurface? {
        if state.disabled { return nil }
        return state.surface == .selected ? .pressed : state.surface
    }

    private var pressed: Bool { surface == .pressed }

    /// A resting or hovered face that is not quiet sits a level above the page; a pressed one sits on it.
    private var raised: Bool { !state.disabled && !pressed && kind != .quiet }

    private var foreground: Color {
        if state.disabled { return DesignTokens.TextColor.tertiary.color }
        return switch kind {
        case .primary, .destructiveFilled: DesignTokens.TextColor.onAccent.color
        case .secondary: DesignTokens.TextColor.primary.color
        case .quiet: DesignTokens.ColorToken.accentText.color
        case .destructive: DesignTokens.Status.problem.text
        }
    }

    private var edge: Color? {
        if state.disabled { return kind == .quiet ? nil : DesignTokens.Surface.separator.color }
        return switch kind {
        case .quiet: nil
        case .secondary: DesignTokens.Surface.strong.color
        case .destructive: surface == nil ? DesignTokens.Surface.strong.color : DesignTokens.Status.problem.badgeFill
        case .primary: DesignTokens.ColorToken.accentPressed.color
        case .destructiveFilled: DesignTokens.Status.problem.text
        }
    }

    @ViewBuilder private func background(_ shape: RoundedRectangle) -> some View {
        if state.disabled {
            if kind != .quiet { shape.fill(DesignTokens.Surface.raised.color) }
        } else {
            switch kind {
            case .primary:
                shape.fill((surface == .pressed ? DesignTokens.ColorToken.accentPressed : surface == .hover ? .accentHover : .accent).color)
            case .destructiveFilled:
                // The problem fill lightens under the pointer and darkens when pressed, as the accent does.
                shape.fill(DesignTokens.Status.problem.tint)
                    .brightness(surface == .pressed ? DesignTokens.Control.pressedBrightness : surface == .hover ? DesignTokens.Control.hoverBrightness : 0)
            case .secondary:
                ZStack {
                    shape.fill((surface == nil ? DesignTokens.Surface.content : DesignTokens.Surface.raised).color)
                    if surface == .pressed { shape.fill(DesignTokens.StateSurface.hover.fill) }
                }
            case .destructive:
                ZStack {
                    shape.fill(DesignTokens.Surface.content.color)
                    if surface != nil { shape.fill(DesignTokens.Status.problem.badgeFill) }
                    if surface == .pressed { shape.fill(DesignTokens.Status.problem.badgeFill) }
                }
            case .quiet:
                if let surface {
                    shape.fill((surface == .pressed ? DesignTokens.ColorToken.accentTintStrong : .accentTint).color)
                }
            }
        }
    }
}

/// A raised face's depth: the first elevation level and the edge highlight along its top.
private struct ButtonDepth<S: Shape>: ViewModifier {
    let raised: Bool
    let shape: S

    func body(content: Content) -> some View {
        if raised {
            content.edgeHighlight(shape).elevation(.level1, in: shape)
        } else {
            content
        }
    }
}

/// The catalog's button as a `ButtonStyle`: the face, given the press, the pointer, keyboard focus and whether the
/// button is enabled. Use it through `directorButton`, which also turns the system's focus effect off, so only the
/// face's ring shows, and takes the reason a disabled button gives.
public struct DirectorButtonStyle: ButtonStyle {
    var kind: ButtonKind = .secondary
    var size: DesignTokens.Control = .medium
    var glyph: String?
    var selected = false

    public init(kind: ButtonKind = .secondary, size: DesignTokens.Control = .medium, glyph: String? = nil, selected: Bool = false) {
        self.kind = kind
        self.size = size
        self.glyph = glyph
        self.selected = selected
    }

    public func makeBody(configuration: Configuration) -> some View {
        Face(configuration: configuration, kind: kind, size: size, glyph: glyph, selected: selected)
    }

    private struct Face: View {
        let configuration: Configuration
        let kind: ButtonKind
        let size: DesignTokens.Control
        let glyph: String?
        let selected: Bool
        @State private var hovered = false
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.isFocused) private var isFocused
        @Environment(\.buttonKeyboardFocus) private var keyboardFocus
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            ButtonFace(
                label: configuration.label,
                kind: kind,
                size: size,
                glyph: glyph,
                state: DesignTokens.Interaction(
                    hovered: hovered, pressed: configuration.isPressed, selected: selected, focused: isFocused || keyboardFocus, disabled: !isEnabled
                ),
                reduceMotion: reduceMotion
            )
            .contentShape(RoundedRectangle(cornerRadius: size.radius, style: .continuous))
            .onHover { hovered = $0 }
        }
    }
}

extension View {
    /// The catalog's button of `kind` at `size`, with `glyph` (an SF Symbol) before its label; `selected` keeps it
    /// pressed while its menu or sheet is open. While `disabledReason` is set the button is off, and the reason shows
    /// under it and is its help: there is no way to turn the button off without saying why.
    public func directorButton(
        _ kind: ButtonKind = .secondary, size: DesignTokens.Control = .medium, glyph: String? = nil, selected: Bool = false,
        disabledReason: String? = nil
    ) -> some View {
        buttonStyle(DirectorButtonStyle(kind: kind, size: size, glyph: glyph, selected: selected))
            .focusEffectDisabled()
            .modifier(ReportsKeyboardFocus())
            .disabledReason(disabledReason)
    }
}

/// Keyboard focus as the button holds it. A button style's body is not the focusable view, so `isFocused` read there
/// stays false on macOS; the button's own focus state, handed down, is what lights the face's ring.
private struct ButtonKeyboardFocusKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var buttonKeyboardFocus: Bool {
        get { self[ButtonKeyboardFocusKey.self] }
        set { self[ButtonKeyboardFocusKey.self] = newValue }
    }
}

/// Tracks whether the button it wraps has keyboard focus and hands that to the button's style.
private struct ReportsKeyboardFocus: ViewModifier {
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .environment(\.buttonKeyboardFocus, focused)
            .focused($focused)
    }
}

// MARK: - Icon button

/// An icon button's face: the glyph alone in a square of the control's height, secondary at rest, on the hover or
/// pressed surface under the pointer, in the accent on the accent tint when a toggle is on, tertiary when off.
public struct IconButtonFace: View {
    let symbol: String
    var size: DesignTokens.Control = .medium
    var on = false
    let state: DesignTokens.Interaction
    let reduceMotion: Bool

    public init(_ symbol: String, size: DesignTokens.Control = .medium, on: Bool = false, state: DesignTokens.Interaction, reduceMotion: Bool) {
        self.symbol = symbol
        self.size = size
        self.on = on
        self.state = state
        self.reduceMotion = reduceMotion
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: size.radius, style: .continuous)
        Image(systemName: symbol)
            .font(size.glyphFont(icon: true))
            // Switching on pops the glyph with a small bounce; under Reduce Motion it just changes.
            .symbolEffect(.bounce, options: .nonRepeating, value: reduceMotion ? false : on)
            .foregroundStyle(foreground)
            .frame(width: size.height, height: size.height)
            .background { if let fill { shape.fill(fill) } }
            .contentShape(shape)
            .focusRing(state.showsFocusRing, shape)
            .scaleEffect(DesignTokens.Motion.scale(DesignTokens.Motion.iconPressScale, pressed: state.pressed && !state.disabled, reduceMotion: reduceMotion))
            .animation(.motion(.fast, reduceMotion: reduceMotion), value: state)
            .animation(.motion(.fast, reduceMotion: reduceMotion), value: on)
    }

    private var foreground: Color {
        if state.disabled { return DesignTokens.TextColor.tertiary.color }
        if on { return DesignTokens.ColorToken.accentText.color }
        return (state.hovered || state.pressed ? DesignTokens.TextColor.primary : DesignTokens.TextColor.secondary).color
    }

    private var fill: Color? {
        if state.disabled { return nil }
        if state.pressed { return DesignTokens.StateSurface.pressed.fill }
        if on { return DesignTokens.StateSurface.selected.fill }
        if state.hovered { return DesignTokens.StateSurface.hover.fill }
        return nil
    }
}

/// The live icon button's style: the face given the press, the pointer, keyboard focus and whether it is enabled.
private struct IconButtonStyle: ButtonStyle {
    let symbol: String
    let size: DesignTokens.Control
    let on: Bool

    func makeBody(configuration: Configuration) -> some View {
        Face(configuration: configuration, symbol: symbol, size: size, on: on)
    }

    private struct Face: View {
        let configuration: Configuration
        let symbol: String
        let size: DesignTokens.Control
        let on: Bool
        @State private var hovered = false
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.isFocused) private var isFocused
        @Environment(\.buttonKeyboardFocus) private var keyboardFocus
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            IconButtonFace(
                symbol, size: size, on: on,
                state: DesignTokens.Interaction(hovered: hovered, pressed: configuration.isPressed, focused: isFocused || keyboardFocus, disabled: !isEnabled),
                reduceMotion: reduceMotion
            )
            .onHover { hovered = $0 }
        }
    }
}

/// The catalog's icon button: an SF Symbol alone, for toolbars and card corners where the glyph is well known (close,
/// more, refresh, the details pane). `help` names the action: it is the help text and what VoiceOver reads. The
/// toggle form (`isOn`) shows its on state in the accent tint. While `disabledReason` is set it is off, and the reason
/// is its help and shows under it.
public struct IconButton: View {
    let symbol: String
    let help: String
    var size: DesignTokens.Control
    var isOn: Binding<Bool>?
    var shortcut: KeyboardShortcut?
    var disabledReason: String?
    var reasonAlignment: HorizontalAlignment
    let action: () -> Void

    /// An icon button that runs `action`, also on `shortcut`.
    public init(
        _ symbol: String, help: String, size: DesignTokens.Control = .medium, shortcut: KeyboardShortcut? = nil, disabledReason: String? = nil,
        reasonAlignment: HorizontalAlignment = .center, action: @escaping () -> Void
    ) {
        self.symbol = symbol
        self.help = help
        self.size = size
        self.shortcut = shortcut
        self.disabledReason = disabledReason
        self.reasonAlignment = reasonAlignment
        self.action = action
    }

    /// A toggle: pressing it flips `isOn`, and it shows on in the accent tint.
    public init(
        _ symbol: String, help: String, size: DesignTokens.Control = .medium, isOn: Binding<Bool>, shortcut: KeyboardShortcut? = nil,
        disabledReason: String? = nil, reasonAlignment: HorizontalAlignment = .center
    ) {
        self.symbol = symbol
        self.help = help
        self.size = size
        self.isOn = isOn
        self.shortcut = shortcut
        self.disabledReason = disabledReason
        self.reasonAlignment = reasonAlignment
        self.action = { isOn.wrappedValue.toggle() }
    }

    public var body: some View {
        let button = Button(action: action) {
            Image(systemName: symbol)
        }
        .buttonStyle(IconButtonStyle(symbol: symbol, size: size, on: isOn?.wrappedValue ?? false))
        .keyboardShortcut(shortcut)
        .focusEffectDisabled()
        .modifier(ReportsKeyboardFocus())
        .accessibilityLabel(help)
        .accessibilityAddTraits(isOn == nil ? [] : .isToggle)
        .accessibilityValue(isOn.map { $0.wrappedValue ? "On" : "Off" } ?? "")
        if disabledReason == nil {
            button.help(help)
        } else {
            button.disabledReason(disabledReason, alignment: reasonAlignment)
        }
    }
}

// MARK: - Disabled with its reason

/// The reason a control is off (the catalog's inline refusal): a lock and the sentence, in one line under the control
/// or on its own in a row or a card, with a way to fix it when the Director can do something about it.
public struct Refusal: View {
    let reason: String
    var fix: String?
    var perform: (() -> Void)?

    public init(reason: String, fix: String? = nil, perform: (() -> Void)? = nil) {
        self.reason = reason
        self.fix = fix
        self.perform = perform
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Control.glyphGap) {
            Image(systemName: "lock.fill")
                .font(DesignTokens.Control.small.glyphFont())
                .foregroundStyle(DesignTokens.TextColor.tertiary.color)
                .accessibilityHidden(true)
            Text(reason)
                .font(DesignTokens.TypeStyle.secondary.font)
                .foregroundStyle(DesignTokens.TextColor.secondary.color)
                .fixedSize(horizontal: false, vertical: true)
            if let fix, let perform {
                Button(fix, action: perform)
                    .buttonStyle(.plain)
                    .font(DesignTokens.TypeStyle.secondary.font.weight(.medium))
                    .foregroundStyle(DesignTokens.ColorToken.accentText.color)
                    .fixedSize()
            }
        }
        .modifier(CappedWidth(width: DesignTokens.Measure.width(DesignTokens.Measure.narrowCharacters, for: .secondary)))
    }
}

/// Wraps its content at `width` (the narrow measure) without taking more room than the content needs. Its size is the
/// same whatever its container proposes: a narrow probe would otherwise wrap it a word a line, and that height would
/// become the window's minimum height and push the window's bottom bar off screen.
private struct CappedWidth: ViewModifier {
    let width: Double

    func body(content: Content) -> some View {
        CappedWidthLayout(width: CGFloat(width)) { content }
    }
}

private struct CappedWidthLayout: Layout {
    let width: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let ideal = content.sizeThatFits(.unspecified).width
        return content.sizeThatFits(ProposedViewSize(width: min(ideal, width), height: nil))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

/// A control that is off for `reason`: it draws disabled with the not-allowed pointer, its help and VoiceOver hint
/// say why, and the reason shows under it at once. No reason: the control as it is.
private struct DisabledReason: ViewModifier {
    let reason: String?
    let alignment: HorizontalAlignment

    func body(content: Content) -> some View {
        if let reason {
            VStack(alignment: alignment, spacing: DesignTokens.Control.glyphGap) {
                content
                    .disabled(true)
                    .notAllowedPointer(true)
                    .help(reason)
                    .accessibilityHint(reason)
                Refusal(reason: reason).transition(.opacity)
            }
        } else {
            content
        }
    }
}

extension View {
    /// Turns the control off while `reason` is set: the reason shows under it, at `alignment`, and is its help.
    public func disabledReason(_ reason: String?, alignment: HorizontalAlignment = .leading) -> some View {
        modifier(DisabledReason(reason: reason, alignment: alignment))
    }

    /// The pointer says not allowed over a control that can't act.
    public func notAllowedPointer(_ notAllowed: Bool) -> some View {
        modifier(NotAllowedPointer(notAllowed: notAllowed))
    }
}

/// Pushes the not-allowed cursor while the pointer is over a refused control, and pops exactly what it pushed: on
/// hover-exit whatever the read says now, when a new read allows the control under the pointer, and when the control
/// leaves the view tree without a hover-exit (a move changing place on the rail).
private struct NotAllowedPointer: ViewModifier {
    let notAllowed: Bool
    @State private var hovering = false
    @State private var pushed = false

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                hovering = inside
                update()
            }
            .onChange(of: notAllowed) { update() }
            .onDisappear {
                hovering = false
                update()
            }
    }

    private func update() {
        let want = hovering && notAllowed
        if want, !pushed {
            NSCursor.operationNotAllowed.push()
            pushed = true
        } else if !want, pushed {
            NSCursor.pop()
            pushed = false
        }
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
