import SwiftUI
import SymphonyBarCore

// A time-of-day field (TP-1574): the hour and minute of a setting (when updates install), on the 24-hour clock, in the
// text field's surface with the number field's stepper. Every measure and every rule of its value is
// `DesignTokens.TimeField`'s.

/// An hour and a minute: its label above (unless it sits in a `SettingsRow`, whose label it takes), "03:00" in a text
/// field's surface with the stepper at its trailing end, and under it the help, the error, or the reason it is off,
/// never two. A click on the hour or the minute gives it the keyboard and the accent tint; Up and Down (or the stepper)
/// step it, wrapping around without carrying into the other; Left and Right move between them; digits type it, and a
/// part typed whole moves on to the minute. VoiceOver reads each part with its value, and adjusts it.
///
/// `drawnAs` draws the field still in a state, for the Component Gallery (`drawnPart` the part with the keyboard); it
/// is live otherwise.
public struct TimeField: View {
    public typealias Part = DesignTokens.TimeField.Part

    let label: String?
    @Binding var time: TimeOfDay
    var help: String?
    var error: String?
    var disabledReason: String?
    var size: DesignTokens.Control
    var drawnAs: DesignTokens.Field.State?
    var drawnPart: Part?

    @State private var hovering = false
    @State private var pending: Int?
    @FocusState private var focus: Part?
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.settingsRowLabel) private var rowLabel
    @Environment(\.settingsRowInvalid) private var rowInvalid
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.offscreenSnapshot) private var offscreenSnapshot

    public init(
        _ label: String? = nil, time: Binding<TimeOfDay>, help: String? = nil, error: String? = nil,
        disabledReason: String? = nil, size: DesignTokens.Control = .medium, drawnAs: DesignTokens.Field.State? = nil,
        drawnPart: Part? = nil
    ) {
        self.label = label
        _time = time
        self.help = help
        self.error = error
        self.disabledReason = disabledReason
        self.size = size
        self.drawnAs = drawnAs
        self.drawnPart = drawnPart
    }

    private var footnote: DesignTokens.Field.Footnote? {
        DesignTokens.Field.footnote(help: help, error: error, disabledReason: disabledReason)
    }
    private var disabled: Bool { disabledReason != nil || !isEnabled }
    private var invalid: Bool {
        if case .error? = footnote { return true }
        return rowInvalid
    }
    private var still: Bool { drawnAs != nil || offscreenSnapshot }
    private var state: DesignTokens.Field.State {
        if let drawnAs { return drawnAs }
        if disabled { return .rest }
        return focus != nil ? .focused : hovering ? .hover : .rest
    }
    private var keyboardPart: Part? { still ? drawnPart : focus }
    private var name: String { label ?? rowLabel ?? "" }

    public var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Field.gap) {
            if let label, !label.isEmpty {
                Text(label)
                    .textStyle(.label)
                    .foregroundStyle(DesignTokens.TextColor.secondary.color)
                    .accessibilityHidden(true)
            }
            input.fixedSize(horizontal: true, vertical: false)
            if let footnote { FieldFootnote(footnote: footnote) }
        }
        .animation(.motion(.standard, reduceMotion: reduceMotion), value: footnote)
        .onChange(of: focus) { _, _ in pending = nil }
    }

    private var input: some View {
        let shape = RoundedRectangle(cornerRadius: size.radius, style: .continuous)
        return HStack(spacing: 0) {
            HStack(spacing: 0) {
                part(.hour)
                Text(DesignTokens.TimeField.separator)
                    .foregroundStyle(textColor)
                    .accessibilityHidden(true)
                part(.minute)
            }
            .font(size.inputFont)
            .monospacedDigit()
            .padding(.horizontal, size.padding * DesignTokens.Field.paddingScale)
            .frame(minWidth: DesignTokens.TimeField.width, alignment: .leading)
            FieldStepper(size: size, upEnabled: true, downEnabled: true, disabled: disabled) { stepBy($0) }
        }
        .frame(height: size.height)
        .clipShape(shape)
        .modifier(FieldSurface(shape: shape, kind: .text, state: state, invalid: invalid, disabled: disabled, reduceMotion: reduceMotion))
        .contentShape(shape)
        .onHover { hovering = $0 }
        .onTapGesture { if !disabled, !still, focus == nil { focus = .hour } }
        .notAllowedPointer(disabled)
        .help(disabledReason ?? "")
        .accessibilityElement(children: .contain)
        .accessibilityLabel(name)
    }

    private var textColor: Color { (disabled ? DesignTokens.TextColor.tertiary : DesignTokens.TextColor.primary).color }

    private func part(_ part: Part) -> some View {
        let tokens = DesignTokens.TimeField.self
        let tinted = keyboardPart == part && !disabled
        return Text(tokens.digits(time, part))
            .foregroundStyle(textColor)
            .padding(.horizontal, tokens.partPadding)
            .background {
                if tinted { RoundedRectangle(cornerRadius: tokens.partRadius, style: .continuous).fill(tokens.partTint.fill) }
            }
            .contentShape(Rectangle())
            .onTapGesture { if !disabled, !still { focus = part } }
            .focusable(!disabled && !still)
            .focusEffectDisabled()
            .focused($focus, equals: part)
            .onKeyPress(.upArrow) { key { stepBy(1) } }
            .onKeyPress(.downArrow) { key { stepBy(-1) } }
            .onKeyPress(.leftArrow) { key { move(forward: false) } }
            .onKeyPress(.rightArrow) { key { move(forward: true) } }
            .onKeyPress(characters: .decimalDigits) { press in
                guard let digit = press.characters.first?.wholeNumberValue else { return .ignored }
                return key { type(digit, into: part) }
            }
            .accessibilityElement()
            .accessibilityLabel("\(name) \(part.spoken)")
            .accessibilityValue(tokens.digits(time, part))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: step(part, by: 1)
                case .decrement: step(part, by: -1)
                @unknown default: break
                }
            }
    }

    private func key(_ action: () -> Void) -> KeyPress.Result {
        guard !disabled else { return .ignored }
        action()
        return .handled
    }

    /// The stepper and the arrow keys step the part with the keyboard, the minute when neither has it.
    private func stepBy(_ by: Int) {
        step(focus ?? .minute, by: by)
    }

    private func step(_ part: Part, by: Int) {
        guard !disabled else { return }
        pending = nil
        time = DesignTokens.TimeField.step(time, part, by: by)
    }

    private func move(forward: Bool) {
        guard let focus, let next = DesignTokens.TimeField.neighbour(of: focus, forward: forward) else { return }
        self.focus = next
    }

    private func type(_ digit: Int, into part: Part) {
        let typed = DesignTokens.TimeField.type(digit, into: part, after: pending)
        time = DesignTokens.TimeField.setting(time, part, to: typed.value)
        pending = typed.pending
        if typed.done, let next = DesignTokens.TimeField.neighbour(of: part, forward: true) { focus = next }
    }
}
