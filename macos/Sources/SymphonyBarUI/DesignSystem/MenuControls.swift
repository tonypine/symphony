import AppKit
import SwiftUI
import SymphonyBarCore

// C53 Pop-up and C54 Menu button, the catalog's `.popup` and `.menu-btn` (TP-1508): a control that opens the app's
// menu (`MenuList`, shown by `MenuPresenter`), never a stock `Menu` or `Picker`.

/// What a menu control shows: a menu button's title with an optional leading glyph, or a pop-up's label and value,
/// with the accent dot after the value when `marked` (a saved view the bar has changed).
public enum MenuControlContent: Equatable {
    case menu(title: String, glyph: String?)
    case popUp(label: String?, value: String, marked: Bool = false)
}

/// One state of a pop-up or a menu button: the secondary button's face with the label (and a pop-up's value in the
/// primary colour after its label in the secondary), then the chevron: up-down for a pop-up, down for a menu button,
/// turned over while its menu is open. Hover lightens it and deepens its shadow, a press settles it to 97 %, open puts
/// the accent edge and its tint ring round it, keyboard focus the focus ring, and disabled is tertiary on the raised
/// surface. The quiet form ("Filter") has no surface and no chevron, its words and glyph in the accent. A pop-up's
/// value may be an identifier, in the mono face (`monoValue`), or come from a default, in the tertiary colour at the
/// regular weight (`inheritedValue`), as the Searchable pop-up draws them.
public struct MenuControlFace: View {
    let content: MenuControlContent
    var size: DesignTokens.Control
    var quiet: Bool
    let state: DesignTokens.Interaction
    var open: Bool
    var monoValue: Bool
    var inheritedValue: Bool
    let reduceMotion: Bool

    public init(
        _ content: MenuControlContent, size: DesignTokens.Control = .medium, quiet: Bool = false, state: DesignTokens.Interaction = .rest,
        open: Bool = false, monoValue: Bool = false, inheritedValue: Bool = false, reduceMotion: Bool
    ) {
        self.content = content
        self.size = size
        self.quiet = quiet
        self.state = state
        self.open = open
        self.monoValue = monoValue
        self.inheritedValue = inheritedValue
        self.reduceMotion = reduceMotion
    }

    private var isOpen: Bool { open && !state.disabled }
    private var isPopUp: Bool { if case .popUp = content { true } else { false } }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: size.radius, style: .continuous)
        HStack(spacing: DesignTokens.Space.s2) {
            switch content {
            case let .menu(title, glyph):
                if let glyph {
                    Image(systemName: glyph)
                        .font(size.glyphFont())
                        .foregroundStyle(glyphColor)
                        .accessibilityHidden(true)
                }
                Text(title)
            case let .popUp(label, value, marked):
                if let label, !label.isEmpty {
                    Text(label).foregroundStyle(state.disabled ? DesignTokens.TextColor.tertiary.color : DesignTokens.TextColor.secondary.color)
                }
                HStack(spacing: DesignTokens.MenuControl.markGap) {
                    valueText(value)
                    if marked {
                        Circle()
                            .fill(DesignTokens.ColorToken.accent.color)
                            .frame(width: DesignTokens.MenuControl.mark, height: DesignTokens.MenuControl.mark)
                            .accessibilityHidden(true)
                    }
                }
            }
            if !quiet || isPopUp {
                Image(systemName: isPopUp ? DesignTokens.MenuControl.popUpSymbol : DesignTokens.MenuControl.menuSymbol)
                    .font(DesignTokens.TypeStyle.font(size: DesignTokens.MenuControl.chevron, weight: DesignTokens.TypeStyle.label.weight))
                    .foregroundStyle((state.disabled ? DesignTokens.TextColor.tertiary : DesignTokens.TextColor.secondary).color)
                    .rotationEffect(.degrees(isOpen && !isPopUp ? 180 : 0))
                    .accessibilityHidden(true)
            }
        }
        .font(size.labelFont)
        .lineLimit(1)
        .lineHeight(.exact(points: size.labelLineHeight))
        .foregroundStyle(foreground)
        .padding(.leading, size.padding)
        .padding(.trailing, quiet && !isPopUp ? size.padding : size.padding * DesignTokens.MenuControl.trailingScale)
        .frame(height: size.height)
        .background { background(shape) }
        .overlay {
            if let edge { shape.strokeBorder(edge, lineWidth: DesignTokens.Control.edgeWidth) }
        }
        .overlay {
            if isOpen, !quiet {
                let ring = DesignTokens.MenuControl.openRingWidth
                shape.inset(by: -ring / 2).stroke(DesignTokens.ColorToken.accentTint.color, lineWidth: ring).allowsHitTesting(false)
            }
        }
        .modifier(MenuControlDepth(raised: !quiet && !state.disabled && !isOpen, hovered: state.hovered && !state.pressed, shape: shape))
        .focusRing(state.showsFocusRing, shape)
        .scaleEffect(DesignTokens.Motion.scale(DesignTokens.Motion.pressScale, pressed: state.pressed && !state.disabled, reduceMotion: reduceMotion))
        .animation(.motion(.instant, reduceMotion: reduceMotion), value: state)
        .animation(.motion(.fold, reduceMotion: reduceMotion), value: isOpen)
    }

    /// A pop-up's value: in the label's font, or the mono face for an identifier, and tertiary at the regular weight
    /// when it comes from a default.
    @ViewBuilder private func valueText(_ value: String) -> some View {
        let text = Text(value)
        let weight = inheritedValue ? DesignTokens.SearchableList.inheritedWeight : DesignTokens.TypeStyle.label.weight
        let styled = text.font(monoValue ? DesignTokens.TypeStyle.monoFont(weight: weight) : inheritedValue ? DesignTokens.TypeStyle.font(size: size.fontSize, weight: weight) : size.labelFont)
        if inheritedValue, !state.disabled {
            styled.foregroundStyle(DesignTokens.TextColor.tertiary.color)
        } else {
            styled
        }
    }

    private var foreground: Color {
        if state.disabled { return DesignTokens.TextColor.tertiary.color }
        return quiet ? DesignTokens.ColorToken.accentText.color : DesignTokens.TextColor.primary.color
    }

    private var glyphColor: Color {
        if state.disabled { return DesignTokens.TextColor.tertiary.color }
        return quiet ? DesignTokens.ColorToken.accentText.color : DesignTokens.TextColor.secondary.color
    }

    private var edge: Color? {
        if quiet { return nil }
        if state.disabled { return DesignTokens.Surface.separator.color }
        return isOpen ? DesignTokens.ColorToken.accent.color : DesignTokens.Surface.strong.color
    }

    @ViewBuilder private func background(_ shape: RoundedRectangle) -> some View {
        if quiet {
            if !state.disabled, state.pressed || state.hovered || isOpen {
                shape.fill((state.pressed || isOpen ? DesignTokens.ColorToken.accentTintStrong : .accentTint).color)
            }
        } else {
            let lifted = state.disabled || state.hovered || state.pressed || isOpen
            shape.fill((lifted ? DesignTokens.Surface.raised : DesignTokens.Surface.content).color)
        }
    }
}

/// A raised face's depth: the first elevation at rest and the second under the pointer, with the edge highlight; none
/// while open or off. The face keeps one view tree in every state (only the shadows and the highlight change), so
/// opening and closing its menu never rebuilds the control under the pointer.
private struct MenuControlDepth<S: Shape>: ViewModifier {
    let raised: Bool
    let hovered: Bool
    let shape: S

    func body(content: Content) -> some View {
        content
            .overlay {
                if raised { Color.clear.edgeHighlight(shape) }
            }
            .elevation(raised ? (hovered ? .level2 : .level1) : .level0, in: shape)
    }
}

/// The live face: the press, the pointer, keyboard focus and whether it is on.
private struct MenuControlStyle: ButtonStyle {
    let content: MenuControlContent
    let size: DesignTokens.Control
    let quiet: Bool
    let open: Bool
    var monoValue = false
    var inheritedValue = false

    func makeBody(configuration: Configuration) -> some View {
        Face(configuration: configuration, content: content, size: size, quiet: quiet, open: open, monoValue: monoValue, inheritedValue: inheritedValue)
    }

    private struct Face: View {
        let configuration: Configuration
        let content: MenuControlContent
        let size: DesignTokens.Control
        let quiet: Bool
        let open: Bool
        let monoValue: Bool
        let inheritedValue: Bool
        @State private var hovered = false
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.buttonKeyboardFocus) private var keyboardFocus
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            MenuControlFace(
                content, size: size, quiet: quiet,
                state: DesignTokens.Interaction(hovered: hovered, pressed: configuration.isPressed, focused: keyboardFocus, disabled: !isEnabled),
                open: open, monoValue: monoValue, inheritedValue: inheritedValue, reduceMotion: reduceMotion
            )
            .contentShape(RoundedRectangle(cornerRadius: size.radius, style: .continuous))
            .onHover { hovered = $0 }
        }
    }
}


/// The control's button: it opens the menu on a click, Space, Return or Down, from the anchor's place on screen. To
/// VoiceOver the anchor is the control: a pop-up button with its value, or a menu button, that a press opens (an
/// AppKit element, so no stock control is built for it).
struct MenuTrigger: View {
    let content: MenuControlContent
    let size: DesignTokens.Control
    let quiet: Bool
    let monoValue: Bool
    let inheritedValue: Bool
    /// A searchable list's search: its typed letters go to the field.
    let search: MenuSearch?
    let alignment: MenuNavigation.Alignment
    let label: String
    let drawnOpen: Bool
    let role: NSAccessibility.Role
    let spokenLabel: String?
    let spokenValue: String?
    let reason: String?
    let items: () -> (items: [MenuItem], highlighted: Int?)
    @State private var open = false
    @State private var anchor = MenuAnchorBox()
    @Environment(\.offscreenSnapshot) private var offscreenSnapshot

    init(
        content: MenuControlContent, size: DesignTokens.Control, quiet: Bool, monoValue: Bool = false, inheritedValue: Bool = false,
        search: MenuSearch? = nil, alignment: MenuNavigation.Alignment, label: String, drawnOpen: Bool, role: NSAccessibility.Role = .menuButton,
        spokenLabel: String? = nil, spokenValue: String? = nil, reason: String? = nil,
        items: @escaping () -> (items: [MenuItem], highlighted: Int?)
    ) {
        self.content = content
        self.size = size
        self.quiet = quiet
        self.monoValue = monoValue
        self.inheritedValue = inheritedValue
        self.search = search
        self.alignment = alignment
        self.label = label
        self.drawnOpen = drawnOpen
        self.role = role
        self.spokenLabel = spokenLabel
        self.spokenValue = spokenValue
        self.reason = reason
        self.items = items
    }

    /// Drawn open while its menu is: `open` redraws the face when it closes, and the presenter has the last word.
    private var shown: Bool { open && MenuPresenter.showing(for: anchor) != nil }

    var body: some View {
        Button(action: toggle) { Text(label) }
            .buttonStyle(MenuControlStyle(
                content: content, size: size, quiet: quiet, open: shown || drawnOpen, monoValue: monoValue, inheritedValue: inheritedValue
            ))
            .focusEffectDisabled()
            .modifier(ReportsKeyboardFocus())
            .accessibilityHidden(true)
            .background {
                // An offscreen snapshot can't draw an AppKit view, and needs no place on screen.
                if !offscreenSnapshot {
                    MenuAnchor(box: anchor, access: MenuAnchorAccess(
                        role: role, label: spokenLabel ?? label, value: spokenValue, help: reason, enabled: reason == nil, expanded: shown,
                        press: toggle
                    ))
                }
            }
            .onKeyPress(.downArrow) {
                toggle()
                return .handled
            }
            .onKeyPress(.return) {
                toggle()
                return .handled
            }
            .fixedSize()
            .onDisappear {
                // Whatever is left of its menu goes with it, on screen or not.
                if let current = MenuPresenter.current, current.owner === anchor { current.session.close() }
            }
    }

    /// Closes this control's menu when it is the one on screen, and opens it otherwise. Whether it is open is the
    /// presenter's to say, not `open`'s: `open` only draws the face, so a close it missed (Escape, a click outside),
    /// or a menu that left the screen without closing, can never leave the control unable to open again. Opening
    /// closes what is left of any other menu first.
    private func toggle() {
        if let shown = MenuPresenter.showing(for: anchor) {
            shown.session.close()
            return
        }
        guard let view = anchor.view else { return }
        let menu = items()
        let opened = MenuPresenter.open(
            menu.items, from: view, alignment: alignment, minWidth: max(DesignTokens.Menu.minWidth, view.bounds.width),
            highlighted: menu.highlighted, search: search, label: label, owner: anchor
        ) { open = false }
        open = opened != nil
    }
}

// MARK: - Menu button

/// C54, the catalog's Menu button: a labelled button, with an optional leading glyph, that opens a short menu of
/// related moves (`MenuItem`s, built when it opens). The label names the set and ends with "…" or the chevron; a
/// destructive item sits last, under a separator, in the problem colour. `quiet` is the bar's form with no surface
/// and accent words ("Filter"). While `disabledReason` is set it is off, and the reason shows under it.
public struct MenuButton: View {
    let content: MenuControlContent
    let title: String
    var size: DesignTokens.Control
    var quiet: Bool
    var alignment: MenuNavigation.Alignment
    var help: String?
    var accessibilityText: String?
    var disabledReason: String?
    var drawnOpen: Bool
    let items: () -> [MenuItem]

    /// `drawnOpen` draws the menu open under the button, still, for a snapshot. `help` is the help text;
    /// `accessibilityLabel`, what VoiceOver reads when the title alone is not enough.
    public init(
        _ title: String, glyph: String? = nil, size: DesignTokens.Control = .medium, quiet: Bool = false,
        alignment: MenuNavigation.Alignment = .leading, help: String? = nil, accessibilityLabel: String? = nil,
        disabledReason: String? = nil, drawnOpen: Bool = false, items: @escaping () -> [MenuItem]
    ) {
        content = .menu(title: title, glyph: glyph)
        self.title = title
        self.size = size
        self.quiet = quiet
        self.alignment = alignment
        self.help = help
        accessibilityText = accessibilityLabel
        self.disabledReason = disabledReason
        self.drawnOpen = drawnOpen
        self.items = items
    }

    /// A menu button on the pop-up's face: `label` and `value` with the up-down chevron, for a menu that both picks and
    /// moves (the Tickets bar's views: pick a view, save it, rename it). `marked` puts the accent dot after the value.
    public init(
        popUp label: String?, value: String, marked: Bool = false, size: DesignTokens.Control = .medium,
        help: String? = nil, accessibilityLabel: String? = nil, disabledReason: String? = nil, drawnOpen: Bool = false,
        items: @escaping () -> [MenuItem]
    ) {
        content = .popUp(label: label, value: value, marked: marked)
        title = [label, value].compactMap { $0 }.joined(separator: " ")
        self.size = size
        quiet = false
        alignment = .leading
        self.help = help
        accessibilityText = accessibilityLabel
        self.disabledReason = disabledReason
        self.drawnOpen = drawnOpen
        self.items = items
    }

    public var body: some View {
        let trigger = MenuTrigger(
            content: content, size: size, quiet: quiet, alignment: alignment, label: title,
            drawnOpen: drawnOpen && disabledReason == nil, spokenLabel: accessibilityText, reason: disabledReason
        ) { (items(), nil) }
        VStack(alignment: alignment == .trailing ? .trailing : .leading, spacing: DesignTokens.Menu.gap) {
            if let help, disabledReason == nil {
                trigger.help(help)
            } else {
                trigger.disabledReason(disabledReason)
            }
            if drawnOpen, disabledReason == nil {
                MenuList(items: items())
            }
        }
    }
}

// MARK: - Pop-up

/// One choice of a pop-up: the value it stands for, its word, why it is off when it is, and a separator before it.
public struct PopUpChoice<Value: Hashable> {
    public var value: Value
    public var title: String
    public var disabledReason: String?
    public var separatorBefore: Bool

    public init(_ value: Value, _ title: String, disabledReason: String? = nil, separatorBefore: Bool = false) {
        self.value = value
        self.title = title
        self.disabledReason = disabledReason
        self.separatorBefore = separatorBefore
    }
}

/// C53, the catalog's Pop-up: one choice out of a list too long for a segmented control, a repo, an epic, a unit.
/// The label names what is chosen and the value shows the choice; the open list ticks the current one and opens with
/// it lit, Up and Down move, Return picks. VoiceOver reads it as a pop-up button with its value. While
/// `disabledReason` is set it is off, and the reason shows under it.
public struct PopUp<Value: Hashable>: View {
    let label: String?
    @Binding var selection: Value
    let choices: [PopUpChoice<Value>]
    var value: String?
    var size: DesignTokens.Control
    var help: String?
    var accessibilityText: String?
    var disabledReason: String?
    var drawnOpen: Bool
    var inherited: Bool

    /// `value` stands in for the chosen choice's word on the face (a scope the window chose). `drawnOpen` draws the
    /// list open under it, still, for a snapshot. `inherited` draws the value in the tertiary colour, as one that comes
    /// from a default (`.popup.inherited`).
    public init(
        _ label: String?, selection: Binding<Value>, choices: [PopUpChoice<Value>], value: String? = nil,
        size: DesignTokens.Control = .medium, help: String? = nil, accessibilityLabel: String? = nil, disabledReason: String? = nil,
        drawnOpen: Bool = false, inherited: Bool = false
    ) {
        self.label = label
        _selection = selection
        self.choices = choices
        self.value = value
        self.size = size
        self.help = help
        accessibilityText = accessibilityLabel
        self.disabledReason = disabledReason
        self.drawnOpen = drawnOpen
        self.inherited = inherited
    }

    /// The choices as the open list's items, ticked on the current one, and the current one's line.
    func menu() -> (items: [MenuItem], highlighted: Int?) {
        var items: [MenuItem] = []
        var current: Int?
        for choice in choices {
            if choice.separatorBefore, !items.isEmpty { items.append(.separator) }
            let chosen = choice.value == selection
            if chosen { current = items.count }
            let value = choice.value
            let binding = $selection
            items.append(MenuItem(choice.title, checked: chosen, disabledReason: choice.disabledReason) { binding.wrappedValue = value })
        }
        return (items, current)
    }

    private var shown: String { value ?? choices.first { $0.value == selection }?.title ?? "" }
    private var spoken: String { accessibilityText ?? label ?? "" }

    public var body: some View {
        let trigger = MenuTrigger(
            content: .popUp(label: label, value: shown), size: size, quiet: false, inheritedValue: inherited, alignment: .leading,
            label: spoken.isEmpty ? shown : spoken, drawnOpen: drawnOpen && disabledReason == nil, role: .popUpButton,
            spokenValue: shown, reason: disabledReason, items: menu
        )
        VStack(alignment: .leading, spacing: DesignTokens.Menu.gap) {
            if let help, disabledReason == nil {
                trigger.help(help)
            } else {
                trigger.disabledReason(disabledReason)
            }
            if drawnOpen, disabledReason == nil {
                MenuList(items: menu().items)
            }
        }
    }
}

/// A filter's choices: `all` (nil, every value) first, a separator, then each of `values`.
public func popUpChoices(all: String, _ values: [String]) -> [PopUpChoice<String?>] {
    [PopUpChoice(String?.none, all)] + values.enumerated().map { PopUpChoice(String?.some($1), $1, separatorBefore: $0 == 0) }
}
