import SwiftUI
import SymphonyBarCore

// A number field with its stepper (TP-1574): the whole numbers of a setting (a timeout in seconds, a limit in MB), in
// the text field's surface (`FieldSurface`) with the stepper at its trailing end and the unit after it. Every measure
// and every rule of its value is `DesignTokens.NumberField`'s.

/// The stepper inside a field's trailing end: its up half over its down half, a hairline before them. A half under
/// the pointer takes the hover surface; a half that can't step is tertiary and does nothing.
struct FieldStepper: View {
    let size: DesignTokens.Control
    let upEnabled: Bool
    let downEnabled: Bool
    let disabled: Bool
    /// The half drawn under the pointer, for the gallery: 1 for up, -1 for down.
    var drawnHover: Int?
    let step: (Int) -> Void

    @State private var hovered: Int?

    var body: some View {
        VStack(spacing: 0) {
            half(1, symbol: DesignTokens.NumberField.upSymbol, enabled: upEnabled)
            half(-1, symbol: DesignTokens.NumberField.downSymbol, enabled: downEnabled)
        }
        .frame(width: DesignTokens.NumberField.stepperWidth, height: size.height)
        .overlay(alignment: .leading) { HairlineDivider(.vertical) }
        .accessibilityHidden(true)
    }

    private func half(_ direction: Int, symbol: String, enabled: Bool) -> some View {
        let live = enabled && !disabled
        let shown = drawnHover ?? hovered
        return Image(systemName: symbol)
            .font(DesignTokens.TypeStyle.font(size: DesignTokens.NumberField.stepperGlyph, weight: DesignTokens.Sidebar.currentWeight))
            .foregroundStyle((live ? DesignTokens.TextColor.secondary : DesignTokens.TextColor.tertiary).color)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { if live, shown == direction { Rectangle().fill(DesignTokens.StateSurface.hover.fill) } }
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { hovered = direction } else if hovered == direction { hovered = nil }
            }
            .onTapGesture { if live { step(direction) } }
            .notAllowedPointer(!live)
    }
}

/// A whole number inside a range, typed or stepped: its label above (unless it sits in a `SettingsRow`, whose label
/// it takes), the number in a text field's surface with the stepper at its trailing end, its unit after it, and under
/// it the help, the error, or the reason it is off, never two. Typed text is read when the field lets go of the
/// keyboard or Return is pressed: a whole number is brought inside the range, anything else puts the value back. The
/// stepper and the Up and Down keys step by `step`; the half that would leave the range is off. VoiceOver reads the
/// label and "30 minutes", and adjusts it by a step.
///
/// `drawnAs` draws the field still in a state, for the Component Gallery; it is live otherwise.
public struct NumberField: View {
    let label: String?
    @Binding var value: Int
    let range: ClosedRange<Int>
    var step: Int
    var unit: String?
    var help: String?
    var error: String?
    var disabledReason: String?
    var size: DesignTokens.Control
    var drawnAs: DesignTokens.Field.State?
    var drawnStepperHover: Int?

    @State private var text = ""
    @State private var hovering = false
    @FocusState private var focused: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.settingsRowLabel) private var rowLabel
    @Environment(\.settingsRowInvalid) private var rowInvalid
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.offscreenSnapshot) private var offscreenSnapshot

    /// `drawnStepperHover` draws a half of the stepper under the pointer, for the gallery: 1 for up, -1 for down.
    public init(
        _ label: String? = nil, value: Binding<Int>, in range: ClosedRange<Int>, step: Int = 1, unit: String? = nil,
        help: String? = nil, error: String? = nil, disabledReason: String? = nil, size: DesignTokens.Control = .medium,
        drawnAs: DesignTokens.Field.State? = nil, drawnStepperHover: Int? = nil
    ) {
        self.label = label
        _value = value
        self.range = range
        self.step = max(step, 1)
        self.unit = unit
        self.help = help
        self.error = error
        self.disabledReason = disabledReason
        self.size = size
        self.drawnAs = drawnAs
        self.drawnStepperHover = drawnStepperHover
    }

    private var footnote: DesignTokens.Field.Footnote? {
        DesignTokens.Field.footnote(help: help, error: error, disabledReason: disabledReason)
    }
    private var disabled: Bool { disabledReason != nil || !isEnabled }
    private var invalid: Bool {
        if case .error? = footnote { return true }
        return rowInvalid
    }
    private var state: DesignTokens.Field.State {
        if let drawnAs { return drawnAs }
        if disabled { return .rest }
        return focused ? .focused : hovering ? .hover : .rest
    }
    private var still: Bool { drawnAs != nil || offscreenSnapshot }
    private var shown: Int { DesignTokens.NumberField.clamp(value, to: range) }

    public var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Field.gap) {
            if let label, !label.isEmpty {
                Text(label)
                    .textStyle(.label)
                    .foregroundStyle(DesignTokens.TextColor.secondary.color)
                    .accessibilityHidden(true)
            }
            HStack(spacing: DesignTokens.NumberField.unitGap) {
                input
                if let unit, !unit.isEmpty {
                    Text(unit)
                        .font(size.inputFont)
                        .foregroundStyle((disabled ? DesignTokens.TextColor.tertiary : DesignTokens.TextColor.secondary).color)
                        .lineLimit(1)
                        .accessibilityHidden(true)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            if let footnote { FieldFootnote(footnote: footnote) }
        }
        .animation(.motion(.standard, reduceMotion: reduceMotion), value: footnote)
        .onChange(of: value, initial: true) { _, _ in if !focused { text = "\(shown)" } }
        .onChange(of: focused) { _, now in if !now { commit() } }
    }

    private var input: some View {
        let shape = RoundedRectangle(cornerRadius: size.radius, style: .continuous)
        return HStack(spacing: 0) {
            number
                .font(size.inputFont)
                .monospacedDigit()
                .padding(.horizontal, size.padding * DesignTokens.Field.paddingScale)
                .frame(width: DesignTokens.NumberField.width, alignment: .trailing)
            FieldStepper(
                size: size, upEnabled: DesignTokens.NumberField.canStep(shown, by: step, in: range),
                downEnabled: DesignTokens.NumberField.canStep(shown, by: -step, in: range), disabled: disabled,
                drawnHover: drawnStepperHover, step: { stepBy($0 * step) }
            )
        }
        .frame(height: size.height)
        .clipShape(shape)
        .modifier(FieldSurface(shape: shape, kind: .text, state: state, invalid: invalid, disabled: disabled, reduceMotion: reduceMotion))
        .contentShape(shape)
        .onHover { hovering = $0 }
        .notAllowedPointer(disabled)
        .help(disabledReason ?? "")
    }

    @ViewBuilder private var number: some View {
        let color = (disabled ? DesignTokens.TextColor.tertiary : DesignTokens.TextColor.primary).color
        if still {
            Text("\(shown)")
                .foregroundStyle(color)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .trailing)
        } else {
            TextField(label ?? rowLabel ?? "", text: $text)
                .textFieldStyle(.plain)
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .foregroundStyle(color)
                .focused($focused)
                .disabled(disabled)
                .onSubmit(commit)
                .onKeyPress(.upArrow) { key(step) }
                .onKeyPress(.downArrow) { key(-step) }
                .accessibilityLabel(label ?? rowLabel ?? "")
                .accessibilityValue(DesignTokens.NumberField.spoken(shown, unit: unit))
                .accessibilityHint(help ?? "")
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: stepBy(step)
                    case .decrement: stepBy(-step)
                    @unknown default: break
                    }
                }
        }
    }

    private func key(_ by: Int) -> KeyPress.Result {
        guard !disabled else { return .ignored }
        commit()
        stepBy(by)
        return .handled
    }

    /// Reads the typed text: a whole number sets the value inside the range; anything else puts the value back.
    private func commit() {
        if let typed = DesignTokens.NumberField.parse(text, in: range), typed != value { value = typed }
        text = "\(DesignTokens.NumberField.clamp(value, to: range))"
    }

    private func stepBy(_ by: Int) {
        guard !disabled else { return }
        let next = DesignTokens.NumberField.step(value, by: by, in: range)
        if next != value { value = next }
        text = "\(next)"
    }
}
