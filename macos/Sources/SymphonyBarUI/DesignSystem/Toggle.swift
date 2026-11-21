import SwiftUI
import SymphonyBarCore

// The catalog's Toggle (`.switch` and `.toggle-row` in `components.css`, the Toggle entry in `stories.js`; TP-1574): a
// setting that is on or off, drawn from `DesignTokens.Switch` in place of the system's switch, and its row: the label,
// the one line that says what being on does (or why the setting is off), and the switch at the trailing end.

/// One state of the switch, as the live switch draws it and the gallery draws it still: the sunken track while off,
/// the accent track while on, the white knob at its end; the strong edge (or the brighter accent) under the pointer,
/// the knob stretched toward where it will go while pressed, the focus ring, and the whole at 45 % while off.
public struct SwitchFace: View {
    let on: Bool
    var state: DesignTokens.Interaction
    let reduceMotion: Bool

    public init(on: Bool, state: DesignTokens.Interaction = .rest, reduceMotion: Bool) {
        self.on = on
        self.state = state
        self.reduceMotion = reduceMotion
    }

    public var body: some View {
        let tokens = DesignTokens.Switch.self
        let hovered = state.hovered && !state.disabled
        let pressed = state.pressed && !state.disabled
        ZStack(alignment: .leading) {
            track(hovered: hovered)
            Capsule()
                .fill(tokens.knob.color)
                .elevation(tokens.knobElevation, in: Capsule())
                .frame(width: tokens.knobWidth(pressed: pressed), height: tokens.knobSize)
                .offset(x: tokens.knobInset + tokens.knobOffset(on: on, pressed: pressed))
        }
        .frame(width: tokens.width, height: tokens.height)
        .focusRing(state.showsFocusRing, Capsule())
        .opacity(state.disabled ? tokens.disabledOpacity : 1)
        .animation(.motion(tokens.travel, reduceMotion: reduceMotion), value: on)
        .animation(.motion(.fast, reduceMotion: reduceMotion), value: pressed)
        .animation(.motion(tokens.trackChange, reduceMotion: reduceMotion), value: hovered)
        .accessibilityHidden(true)
    }

    @ViewBuilder private func track(hovered: Bool) -> some View {
        let tokens = DesignTokens.Switch.self
        let fill = tokens.track(on: on, hovered: hovered).color
        ZStack {
            if on {
                Capsule().fill(fill)
            } else {
                // `inset 0 1px 3px var(--shadow-near)` over the sunken surface with the primary text mixed in.
                Capsule().fill(fill.shadow(.inner(color: DesignTokens.ColorToken.shadowNear.color, radius: 1.5, y: 1)))
                Capsule().fill(DesignTokens.TextColor.primary.color.opacity(tokens.offTrackTint))
            }
            Capsule().strokeBorder(tokens.edge(on: on, hovered: hovered).color, lineWidth: tokens.edgeWidth)
        }
    }
}

/// The switch on its own: a click or Space flips it, and the change applies at once. VoiceOver reads it as a switch
/// with its label and "on" or "off". It is off while the view is disabled (as a `SettingsRow` with a reason turns it
/// off). `drawnAs` draws it still in a state, for the Component Gallery.
public struct DirectorSwitch: View {
    let label: String?
    @Binding var isOn: Bool
    var drawnAs: DesignTokens.Interaction?

    @State private var hovered = false
    @State private var pressed = false
    @FocusState private var focused: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.settingsRowLabel) private var rowLabel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// `label` is what VoiceOver reads; inside a `SettingsRow` the row's label is used when it is nil.
    public init(_ label: String? = nil, isOn: Binding<Bool>, drawnAs: DesignTokens.Interaction? = nil) {
        self.label = label
        _isOn = isOn
        self.drawnAs = drawnAs
    }

    private var state: DesignTokens.Interaction {
        var state = drawnAs ?? DesignTokens.Interaction(hovered: hovered, pressed: pressed, focused: focused)
        if !isEnabled { state.disabled = true }
        return state
    }

    public var body: some View {
        SwitchFace(on: isOn, state: state, reduceMotion: reduceMotion)
            .contentShape(Capsule())
            .onHover { hovered = $0 }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in if isEnabled, drawnAs == nil { pressed = true } }
                    .onEnded { value in
                        pressed = false
                        let reach = DesignTokens.Switch.width
                        if abs(value.translation.width) < reach, abs(value.translation.height) < reach { flip() }
                    }
            )
            .focusable(isEnabled && drawnAs == nil)
            .focusEffectDisabled()
            .focused($focused)
            .onKeyPress(.space) {
                flip()
                return .handled
            }
            .accessibilityElement()
            .accessibilityLabel(label ?? rowLabel ?? "")
            .accessibilityValue(DesignTokens.Switch.spoken(on: isOn))
            .accessibilityAddTraits(.isToggle)
            .accessibilityAction { flip() }
    }

    private func flip() {
        guard isEnabled, drawnAs == nil else { return }
        isOn.toggle()
    }
}

/// The catalog's Toggle: a `SettingsRow` of the label, the line that says what being on does, and the switch. With
/// `disabledReason` the setting is off and the reason replaces the effect line. VoiceOver reads "Notify me about new
/// questions, on", with the effect as its help.
public struct DirectorToggle: View {
    let label: String
    @Binding var isOn: Bool
    var effect: String?
    var disabledReason: String?
    var drawnAs: DesignTokens.Interaction?

    public init(
        _ label: String, isOn: Binding<Bool>, effect: String? = nil, disabledReason: String? = nil,
        drawnAs: DesignTokens.Interaction? = nil
    ) {
        self.label = label
        _isOn = isOn
        self.effect = effect
        self.disabledReason = disabledReason
        self.drawnAs = drawnAs
    }

    public var body: some View {
        SettingsRow(label, help: effect, disabledReason: disabledReason) {
            DirectorSwitch(label, isOn: $isOn, drawnAs: drawnAs)
        }
    }
}
