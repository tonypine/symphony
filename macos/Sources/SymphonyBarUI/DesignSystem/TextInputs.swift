import AppKit
import SwiftUI
import SymphonyBarCore

// The catalog's Text field, Search field and multi-line input (`.field`, `.input`, `.input.search`, `.help`,
// `.own-words`, `.tl-compose`; TP-1509). Each types through the system's own text view (a plain `TextField`, or a
// `TextEditor` for several lines), so typing, selection, undo, spelling, dictation, input methods and VoiceOver
// behave as in any Mac field; the app draws only the surface around it, from `DesignTokens.Field`.

extension DesignTokens.Field.Tone {
    var color: Color { token.color.opacity(opacity) }
}

extension DesignTokens.Control {
    /// An input's text: the size's font size at the catalog's 400.
    var inputFont: Font { DesignTokens.TypeStyle.font(size: fontSize, weight: DesignTokens.Field.textWeight) }
}

/// An input's surface in one state: its fill (with the text field's inner shadow at the top), its edge, and the halo
/// outside the edge while focused. The halo eases in on the `fast` curve.
struct FieldSurface<S: InsettableShape>: ViewModifier {
    let shape: S
    let kind: DesignTokens.Field.Kind
    let state: DesignTokens.Field.State
    var invalid = false
    var disabled = false
    var accented = false
    let reduceMotion: Bool

    private var accentedFocus: Bool { accented && state == .focused && !invalid && !disabled }

    func body(content: Content) -> some View {
        let edge = DesignTokens.Field.edge(kind, state, invalid: invalid, disabled: disabled, accented: accented)
        let edgeWidth = accentedFocus ? DesignTokens.Field.accentedFocusEdge : DesignTokens.Field.edgeWidth
        content
            .background { fill }
            .overlay { shape.strokeBorder(edge.color, lineWidth: edgeWidth).allowsHitTesting(false) }
            .background { halo }
            .animation(.motion(.fast, reduceMotion: reduceMotion), value: state)
            .animation(.motion(.fast, reduceMotion: reduceMotion), value: invalid)
    }

    @ViewBuilder private var fill: some View {
        let color = DesignTokens.Field.fill(kind, state, disabled: disabled).color
        if kind == .text, !disabled {
            shape.fill(
                color.shadow(.inner(
                    color: DesignTokens.ColorToken.shadowNear.color, radius: DesignTokens.Field.innerShadowBlur / 2,
                    y: DesignTokens.Field.innerShadowY
                ))
            )
        } else {
            ZStack {
                shape.fill(color)
                if kind == .search, state == .hover, !disabled {
                    shape.fill(DesignTokens.TextColor.primary.color.opacity(DesignTokens.Field.searchHoverOpacity))
                }
            }
        }
    }

    @ViewBuilder private var halo: some View {
        if let halo = DesignTokens.Field.halo(state, invalid: invalid, disabled: disabled, accented: accented) {
            let width = accentedFocus ? DesignTokens.Field.accentedFocusHalo : DesignTokens.Field.haloWidth
            shape.inset(by: -width / 2).stroke(halo.color, lineWidth: width).allowsHitTesting(false)
        }
    }
}

/// The error's shake: the catalog's `ds-shake` once each time `trigger` changes.
private struct Shake: ViewModifier {
    let trigger: Int

    func body(content: Content) -> some View {
        content.keyframeAnimator(initialValue: 0.0, trigger: trigger) { view, offset in
            view.offset(x: offset)
        } keyframes: { _ in
            let duration = DesignTokens.Motion.slowDuration
            let offsets = DesignTokens.Field.shakeOffsets
            let times = DesignTokens.Field.shakeTimes
            KeyframeTrack {
                CubicKeyframe(offsets[0], duration: duration * times[0])
                CubicKeyframe(offsets[1], duration: duration * (times[1] - times[0]))
                CubicKeyframe(offsets[2], duration: duration * (times[2] - times[1]))
                CubicKeyframe(offsets[3], duration: duration * (times[3] - times[2]))
            }
        }
    }
}

/// What sits under a field: the reason it is off (the inline refusal), the error in the problem colour, which rises in,
/// or the help in the secondary colour.
struct FieldFootnote: View {
    let footnote: DesignTokens.Field.Footnote

    var body: some View {
        switch footnote {
        case let .reason(reason):
            Refusal(reason: reason)
        case let .error(error):
            Text(error)
                .font(DesignTokens.TypeStyle.secondary.font)
                .foregroundStyle(DesignTokens.ColorToken.statusProblemText.color)
                .fixedSize(horizontal: false, vertical: true)
                .transition(.opacity.combined(with: .offset(y: DesignTokens.Field.gap)))
        case let .help(help):
            Text(help)
                .font(DesignTokens.TypeStyle.secondary.font)
                .foregroundStyle(DesignTokens.TextColor.secondary.color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Watches Escape while a field has the keyboard, before the window's key equivalents see it, so a sheet's Cancel
/// does not take the key that clears the field. The monitor sees every key of the app, so it takes Escape only when the
/// key belongs to this field: pressed in the field's own window, whose keyboard is the text editor inside the field.
/// An Escape in a sheet over the window, or in another field, is left alone, and so is a key that composes text in an
/// input method.
@MainActor
final class EscapeWatcher {
    /// What Escape does; true when it took the key.
    var perform: () -> Bool = { false }
    /// The view drawn under the field (`EscapeAnchor`): its window and its frame say where the field is.
    weak var anchor: NSView?
    private var monitor: Any?

    nonisolated static let escapeKeyCode: UInt16 = 53

    func start() {
        guard monitor == nil else { return }
        let handler: (NSEvent) -> NSEvent? = { [weak self] event in
            nonisolated(unsafe) let pressed = event
            let taken: Bool = MainActor.assumeIsolated { self?.take(pressed) ?? false }
            return taken ? nil : event
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: handler)
    }

    /// Escape alone, in this field, not one an input method is composing with: what `perform` says.
    func take(_ event: NSEvent) -> Bool {
        guard Self.isPlainEscape(keyCode: event.keyCode, modifiers: event.modifierFlags) else { return false }
        let fieldWindow = anchor?.window
        let editor = fieldWindow?.firstResponder as? NSTextView
        guard Self.belongs(
            eventWindow: event.window, fieldWindow: fieldWindow,
            editorFrame: editor.map { $0.convert($0.bounds, to: nil) },
            fieldFrame: anchor.map { $0.convert($0.bounds, to: nil) } ?? .null
        ) else { return false }
        if let editor, editor.hasMarkedText() { return false }
        return perform()
    }

    /// Escape with no modifier but Caps Lock.
    nonisolated static func isPlainEscape(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        keyCode == escapeKeyCode && modifiers.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock).isEmpty
    }

    /// The key is this field's: pressed in the field's window (not a sheet or another window over it), where the
    /// keyboard is a text editor that sits inside the field's frame (not another field of the same window).
    nonisolated static func belongs(
        eventWindow: AnyObject?, fieldWindow: AnyObject?, editorFrame: CGRect?, fieldFrame: CGRect
    ) -> Bool {
        guard let fieldWindow, eventWindow === fieldWindow, let editorFrame, !fieldFrame.isNull else { return false }
        return fieldFrame.intersects(editorFrame)
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

/// An empty view under a search field that hands the watcher the field's place in its window, and knows from the
/// window itself whether the field has the keyboard. A field in the window's toolbar lives in the toolbar's own view
/// tree, where a focus state from the page never reaches it: the anchor watches the window's first responder, puts
/// the keyboard in the field and takes it back through AppKit, so the field focuses, draws focused and lets go wherever
/// it sits.
struct EscapeAnchor: NSViewRepresentable {
    let watcher: EscapeWatcher
    var editing: (Bool) -> Void = { _ in }

    func makeNSView(context: Context) -> FieldAnchorView {
        let view = FieldAnchorView()
        view.editing = editing
        watcher.anchor = view
        return view
    }

    func updateNSView(_ view: FieldAnchorView, context: Context) {
        view.editing = editing
        watcher.anchor = view
    }
}

/// The anchor's view: see `EscapeAnchor`.
@MainActor
final class FieldAnchorView: NSView {
    /// Called with whether the window's keyboard is in the field, each time the window's first responder changes.
    var editing: (Bool) -> Void = { _ in }
    private var observation: NSKeyValueObservation?
    private var focusWhenShown = false
    private var lastEditing: Bool?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observation = window?.observe(\.firstResponder, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.report() }
        }
        if window != nil, focusWhenShown {
            focusWhenShown = false
            Task { @MainActor [weak self] in self?.focusField() }
        }
    }

    private var fieldFrame: CGRect { window == nil ? .null : convert(bounds, to: nil) }

    /// Whether the window's keyboard is a text editor inside the field.
    var isEditing: Bool {
        guard let editor = window?.firstResponder as? NSTextView else { return false }
        let host = (editor.delegate as? NSView) ?? editor
        return Self.inField(host.convert(host.bounds, to: nil), fieldFrame: fieldFrame)
    }

    private func report() {
        let now = isEditing
        guard now != lastEditing else { return }
        lastEditing = now
        editing(now)
    }

    /// Puts the keyboard in the field's text field; before the field is in a window, as soon as it is.
    func focusField() {
        guard let window else {
            focusWhenShown = true
            return
        }
        guard !isEditing, let root = window.contentView?.superview ?? window.contentView else { return }
        let fields = Self.textFields(in: root)
        let index = Self.pick(fields.map { $0.convert($0.bounds, to: nil) }, fieldFrame: fieldFrame)
        if let index { window.makeFirstResponder(fields[index]) }
    }

    /// Takes the keyboard back from the field: the window keeps it, as when a Mac search field lets go.
    func release() {
        guard isEditing else { return }
        window?.makeFirstResponder(nil)
    }

    private static func textFields(in view: NSView) -> [NSTextField] {
        view.subviews.flatMap { sub -> [NSTextField] in
            if let field = sub as? NSTextField, field.isEditable { return [field] }
            return textFields(in: sub)
        }
    }

    /// A frame lies inside the field: both in the window, and overlapping.
    nonisolated static func inField(_ frame: CGRect, fieldFrame: CGRect) -> Bool {
        !fieldFrame.isNull && !frame.isNull && fieldFrame.intersects(frame)
    }

    /// The first of the window's text fields that sits inside the field.
    nonisolated static func pick(_ frames: [CGRect], fieldFrame: CGRect) -> Int? {
        frames.firstIndex { inField($0, fieldFrame: fieldFrame) }
    }
}

// MARK: - Text field

/// The catalog's Text field: one line of text the Director types (a reason, a name, a number) at one of the three
/// control heights, so it lines up with a button. Its label sits above; under it the help, or the error, never both.
/// Hover strengthens the edge; focus puts the accent edge and a soft accent halo on it; an error turns the edge red,
/// shakes the field once (not under Reduce Motion) and shows the message; with `disabledReason` it is off on the raised
/// surface and the reason shows under it in place of the help.
///
/// `drawnAs` draws the field still in a state, for the Component Gallery; the field is live otherwise, and draws its
/// text still in an offscreen snapshot, which draws no text view. `mono` sets the text in the mono face, for an
/// identifier such as a harness's command (`.h-field input`). `secure` is its secure form, for a key: the text is
/// masked as it is typed and drawn as dots.
public struct DirectorTextField: View {
    let label: String?
    @Binding var text: String
    var placeholder: String
    var help: String?
    var error: String?
    var size: DesignTokens.Control
    var disabledReason: String?
    var focus: FocusState<Bool>.Binding?
    var drawnAs: DesignTokens.Field.State?
    var onSubmit: (() -> Void)?
    var mono: Bool
    var secure: Bool

    @FocusState private var ownFocus: Bool
    @State private var hovering = false
    @State private var shakes = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.offscreenSnapshot) private var offscreenSnapshot

    public init(
        _ label: String?, text: Binding<String>, placeholder: String = "", help: String? = nil, error: String? = nil,
        size: DesignTokens.Control = .medium, disabledReason: String? = nil, focused: FocusState<Bool>.Binding? = nil,
        drawnAs: DesignTokens.Field.State? = nil, mono: Bool = false, secure: Bool = false, onSubmit: (() -> Void)? = nil
    ) {
        self.label = label
        _text = text
        self.placeholder = placeholder
        self.help = help
        self.error = error
        self.size = size
        self.disabledReason = disabledReason
        focus = focused
        self.drawnAs = drawnAs
        self.mono = mono
        self.secure = secure
        self.onSubmit = onSubmit
    }

    /// What a still field draws: the placeholder while empty, the text masked in the secure form.
    nonisolated static func stillText(_ text: String, placeholder: String, secure: Bool) -> String {
        if text.isEmpty { return placeholder }
        return secure ? String(repeating: "•", count: text.count) : text
    }

    private var focusBinding: FocusState<Bool>.Binding { focus ?? $ownFocus }
    private var disabled: Bool { disabledReason != nil }
    private var footnote: DesignTokens.Field.Footnote? {
        DesignTokens.Field.footnote(help: help, error: error, disabledReason: disabledReason)
    }
    private var invalid: Bool { if case .error? = footnote { true } else { false } }
    private var state: DesignTokens.Field.State {
        if let drawnAs { return drawnAs }
        if disabled { return .rest }
        return focusBinding.wrappedValue ? .focused : hovering ? .hover : .rest
    }
    private var still: Bool { drawnAs != nil || offscreenSnapshot }

    public var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Field.gap) {
            if let label, !label.isEmpty {
                Text(label)
                    .textStyle(.label)
                    .foregroundStyle(DesignTokens.TextColor.secondary.color)
                    .accessibilityHidden(true)
            }
            input
            if let footnote { FieldFootnote(footnote: footnote) }
        }
        .animation(.motion(.standard, reduceMotion: reduceMotion), value: footnote)
        .onChange(of: error) { old, new in
            if DesignTokens.Field.footnote(help: nil, error: new, disabledReason: nil) != nil, new != old, !reduceMotion { shakes += 1 }
        }
    }

    private var input: some View {
        let shape = RoundedRectangle(cornerRadius: size.radius, style: .continuous)
        return Group {
            if still {
                Text(Self.stillText(text, placeholder: placeholder, secure: secure))
                    .foregroundStyle((text.isEmpty || disabled ? DesignTokens.TextColor.tertiary : DesignTokens.TextColor.primary).color)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                entry
                    .textFieldStyle(.plain)
                    .labelsHidden()
                    .foregroundStyle((disabled ? DesignTokens.TextColor.tertiary : DesignTokens.TextColor.primary).color)
                    .focused(focusBinding)
                    .disabled(disabled)
                    .onSubmit { onSubmit?() }
                    .accessibilityLabel(label ?? placeholder)
                    .accessibilityHint(help ?? "")
            }
        }
        .font(mono ? DesignTokens.TypeStyle.monoFont(weight: DesignTokens.Field.textWeight) : size.inputFont)
        .padding(.horizontal, size.padding * DesignTokens.Field.paddingScale)
        .frame(height: size.height)
        .modifier(FieldSurface(shape: shape, kind: .text, state: state, invalid: invalid, disabled: disabled, reduceMotion: reduceMotion))
        .contentShape(shape)
        .onTapGesture { if !disabled, !still { focusBinding.wrappedValue = true } }
        .onHover { hovering = $0 }
        .notAllowedPointer(disabled)
        .help(disabledReason ?? "")
        .modifier(Shake(trigger: shakes))
    }

    @ViewBuilder
    private var entry: some View {
        let prompt = Text(placeholder).foregroundStyle(DesignTokens.TextColor.tertiary.color)
        if secure {
            SecureField(label ?? placeholder, text: $text, prompt: prompt)
        } else {
            TextField(label ?? placeholder, text: $text, prompt: prompt)
        }
    }
}

// MARK: - Search field

/// The catalog's Search field: filters what it sits over as the Director types. A sunken capsule with the search
/// glyph, the placeholder and, while empty, its shortcut as a keyboard hint; under the pointer its edge strengthens;
/// focused it lifts to the content colour with the accent halo. With a query it shows the count of `matches` (when
/// given) and a clear button that pops in; with a query and no match, the line under it says what it searched
/// (`searched`). Escape clears the query, and with no query gives up the keyboard. Return calls `onSubmit`.
public struct SearchField: View {
    let placeholder: String
    @Binding var text: String
    var matches: Int?
    var searched: String?
    var shortcut: String?
    var size: DesignTokens.Control
    var focus: FocusState<Bool>.Binding?
    var focusRequest: Binding<Bool>?
    var drawnAs: DesignTokens.Field.State?
    var onSubmit: (() -> Void)?

    @FocusState private var ownFocus: Bool
    @State private var editing = false
    @State private var hovering = false
    @State private var clearHovered = false
    @State private var escape = EscapeWatcher()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.offscreenSnapshot) private var offscreenSnapshot

    /// The clear button's words, for VoiceOver and its help.
    public static let clearTitle = "Clear the search"

    public init(
        _ placeholder: String, text: Binding<String>, matches: Int? = nil, searched: String? = nil,
        shortcut: String? = DesignTokens.Field.searchShortcut, size: DesignTokens.Control = .medium,
        focused: FocusState<Bool>.Binding? = nil, focusRequest: Binding<Bool>? = nil, drawnAs: DesignTokens.Field.State? = nil,
        onSubmit: (() -> Void)? = nil
    ) {
        self.placeholder = placeholder
        _text = text
        self.matches = matches
        self.searched = searched
        self.shortcut = shortcut
        self.size = size
        focus = focused
        self.focusRequest = focusRequest
        self.drawnAs = drawnAs
        self.onSubmit = onSubmit
    }

    private var focusBinding: FocusState<Bool>.Binding { focus ?? $ownFocus }
    private var hasQuery: Bool { DesignTokens.Field.hasQuery(text) }
    /// The keyboard is in the field: by its focus state, or by the window's own first responder (`EscapeAnchor`).
    private var focused: Bool { focusBinding.wrappedValue || editing }
    private var state: DesignTokens.Field.State {
        drawnAs ?? (focused ? .focused : hovering ? .hover : .rest)
    }
    private var still: Bool { drawnAs != nil || offscreenSnapshot }
    private var noMatchLine: String? {
        guard hasQuery, matches == 0, let searched else { return nil }
        return DesignTokens.Field.noMatch(text, searched: searched)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Field.gap) {
            capsule
            if let noMatchLine { FieldFootnote(footnote: .help(noMatchLine)) }
        }
        .animation(.motion(.lift, reduceMotion: reduceMotion), value: hasQuery)
        .onChange(of: focused, initial: true) { _, focused in
            escape.perform = { [text = $text, focus = focusBinding, weak escape] in
                switch DesignTokens.Field.escape(query: text.wrappedValue) {
                case .clear: text.wrappedValue = ""
                case .release:
                    focus.wrappedValue = false
                    (escape?.anchor as? FieldAnchorView)?.release()
                }
                return true
            }
            if focused, !still { escape.start() } else { escape.stop() }
        }
        .onChange(of: focusRequest?.wrappedValue ?? false, initial: true) { (_: Bool, requested: Bool) in
            guard requested, let focusRequest = self.focusRequest else { return }
            focusRequest.wrappedValue = false
            if !still { takeKeyboard() }
        }
        .onDisappear { escape.stop() }
    }

    private var capsule: some View {
        HStack(spacing: DesignTokens.Field.itemGap) {
            Image(systemName: DesignTokens.Field.searchSymbol)
                .font(DesignTokens.TypeStyle.font(size: DesignTokens.Field.searchGlyph, weight: DesignTokens.TypeStyle.label.weight))
                .foregroundStyle(DesignTokens.TextColor.secondary.color)
                .accessibilityHidden(true)
            field
            if hasQuery {
                if let matches {
                    Text(DesignTokens.Field.matches(matches))
                        .font(DesignTokens.TypeStyle.secondary.font)
                        .monospacedDigit()
                        .foregroundStyle(DesignTokens.TextColor.secondary.color)
                        .lineLimit(1)
                        .fixedSize()
                }
                clearButton.transition(.scale.combined(with: .opacity))
            } else if let shortcut {
                KeyboardHint(shortcut)
            }
        }
        .font(size.inputFont)
        .padding(.leading, size.padding * DesignTokens.Field.searchLeadingScale)
        .padding(.trailing, size.padding * DesignTokens.Field.searchTrailingScale)
        .frame(height: size.height)
        .modifier(FieldSurface(shape: Capsule(), kind: .search, state: state, reduceMotion: reduceMotion))
        .background { if !still { EscapeAnchor(watcher: escape) { editing = $0 } } }
        .contentShape(Capsule())
        .onTapGesture { if !still { takeKeyboard() } }
        .onHover { hovering = $0 }
    }

    /// Puts the keyboard in the field, by its focus state and through the window (`EscapeAnchor`).
    private func takeKeyboard() {
        focusBinding.wrappedValue = true
        (escape.anchor as? FieldAnchorView)?.focusField()
    }

    @ViewBuilder private var field: some View {
        if still {
            Text(text.isEmpty ? placeholder : text)
                .foregroundStyle((text.isEmpty ? DesignTokens.TextColor.tertiary : DesignTokens.TextColor.primary).color)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            TextField(placeholder, text: $text, prompt: Text(placeholder).foregroundStyle(DesignTokens.TextColor.tertiary.color))
                .textFieldStyle(.plain)
                .labelsHidden()
                .foregroundStyle(DesignTokens.TextColor.primary.color)
                .focused(focusBinding)
                .onSubmit { onSubmit?() }
                .accessibilityLabel(placeholder)
                // The match count rides on the hint: the field's value stays the typed text, as any Mac text field reports it.
                .accessibilityHint(hasQuery ? (matches.map(DesignTokens.Field.matches) ?? "") : "")
                .accessibilityAddTraits(.isSearchField)
        }
    }

    private var clearButton: some View {
        Button {
            text = ""
            if !still { takeKeyboard() }
        } label: {
            ZStack {
                Circle().fill((clearHovered ? DesignTokens.TextColor.secondary : DesignTokens.TextColor.tertiary).color)
                Image(systemName: DesignTokens.Field.clearSymbol)
                    .font(DesignTokens.TypeStyle.font(size: DesignTokens.Field.clearGlyph, weight: DesignTokens.CountBadge.weight))
                    .foregroundStyle(DesignTokens.Surface.content.color)
            }
            .frame(width: DesignTokens.Field.clearSize, height: DesignTokens.Field.clearSize)
            .contentShape(Circle())
        }
        .buttonStyle(.plainPointer)
        .onHover { clearHovered = $0 }
        .help(Self.clearTitle)
        .accessibilityLabel(Self.clearTitle)
    }
}

// MARK: - Text area

/// The catalog's multi-line input (the own-words field, the box for writing to a ticket): the text field's surface for
/// several lines. It starts `minLines` tall and grows with its text to `maxLines`, then scrolls. Return adds a line;
/// with `send`, ⌘↩ calls it while the area has the keyboard. `accented` keeps the accent edge and its light halo at
/// rest, as under a picked own-words card. While `still` (a sheet covers the window, an offscreen snapshot) its text is
/// drawn as a `Text`, which dims with the window as the system's text view doesn't.
public struct TextArea: View {
    let label: String
    @Binding var text: String
    var placeholder: String
    var hint: String?
    var minLines: Int
    var maxLines: Int
    /// The least the area is tall, its padding in: a control's height (the box above the timeline is the large one's).
    var minHeight: Double?
    var accented: Bool
    var still: Bool
    var focus: FocusState<Bool>.Binding?
    var drawnAs: DesignTokens.Field.State?
    var send: (() -> Void)?

    @FocusState private var ownFocus: Bool
    @State private var hovering = false
    /// The text is taller than `maxLines`, so the area scrolls and may show its scroll bar.
    @State private var overflows = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.offscreenSnapshot) private var offscreenSnapshot

    /// The type the text is set in, and one line of it in the system's text view.
    static let typeStyle = DesignTokens.TypeStyle.body
    static let lineHeight = NSLayoutManager().defaultLineHeight(for: TextArea.typeStyle.nsFont)
    /// The system text view's own room on each side of a line.
    static let textInset: CGFloat = 5

    /// `label` is what VoiceOver reads it as; `hint`, what it reads after. `minHeight` is the least it is tall, nil for
    /// `minLines` alone.
    public init(
        _ label: String, text: Binding<String>, placeholder: String = "", hint: String? = nil,
        minLines: Int = DesignTokens.Field.areaMinLines, maxLines: Int = DesignTokens.Field.areaMaxLines, minHeight: Double? = nil,
        accented: Bool = false,
        still: Bool = false, focused: FocusState<Bool>.Binding? = nil, drawnAs: DesignTokens.Field.State? = nil,
        send: (() -> Void)? = nil
    ) {
        self.label = label
        _text = text
        self.placeholder = placeholder
        self.hint = hint
        let fewest = max(1, minLines)
        self.minLines = fewest
        self.maxLines = max(fewest, maxLines)
        self.minHeight = minHeight
        self.accented = accented
        self.still = still
        focus = focused
        self.drawnAs = drawnAs
        self.send = send
    }

    private var focusBinding: FocusState<Bool>.Binding { focus ?? $ownFocus }
    private var drawsStill: Bool { still || drawnAs != nil || offscreenSnapshot }
    private var state: DesignTokens.Field.State {
        drawnAs ?? (focusBinding.wrappedValue ? .focused : hovering ? .hover : .rest)
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: DesignTokens.Field.areaRadius, style: .continuous)
        // A hidden copy of the text sizes the area: at least `minLines`, at most `maxLines`.
        Text(text.isEmpty || text.hasSuffix("\n") ? text + " " : text)
            .lineLimit(maxLines)
            .padding(.horizontal, Self.textInset)
            .frame(maxWidth: .infinity, minHeight: Self.textHeight(minLines: minLines, minHeight: minHeight), alignment: .topLeading)
            .hidden()
            .background(alignment: .topLeading) {
                // The whole text at the area's width: taller than `maxLines`, and the area scrolls.
                Text(text)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Self.textInset)
                    .hidden()
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height in
                        overflows = Self.overflows(height: height, maxLines: maxLines)
                    }
            }
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .foregroundStyle(DesignTokens.TextColor.tertiary.color)
                        .padding(.horizontal, Self.textInset)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .overlay(alignment: .topLeading) {
                if drawsStill {
                    Text(text)
                        .foregroundStyle(DesignTokens.TextColor.primary.color)
                        .lineLimit(maxLines)
                        .padding(.horizontal, Self.textInset)
                } else {
                    editor
                }
            }
            .font(Self.typeStyle.font)
            .padding(.horizontal, DesignTokens.Control.medium.padding * DesignTokens.Field.paddingScale - Self.textInset)
            .padding(.vertical, DesignTokens.Field.areaVerticalPadding)
            .modifier(FieldSurface(shape: shape, kind: .text, state: state, accented: accented, reduceMotion: reduceMotion))
            .contentShape(shape)
            .onTapGesture { if !drawsStill { focusBinding.wrappedValue = true } }
            .onHover { hovering = $0 }
            .background { sendKey }
    }

    private var editor: some View {
        TextEditor(text: $text)
            .scrollContentBackground(.hidden)
            // No scroll bar while the text fits, even with a mouse's always-drawn scrollers: the catalog draws none.
            .scrollIndicators(overflows ? .automatic : .never)
            .foregroundStyle(DesignTokens.TextColor.primary.color)
            .focused(focusBinding)
            .accessibilityLabel(label)
            .accessibilityHint(hint ?? "")
    }

    /// The least the text's room is tall: `minLines` lines, or what `minHeight` leaves inside the padding when that is
    /// more.
    static func textHeight(minLines: Int, minHeight: Double?) -> CGFloat {
        max(lineHeight * CGFloat(minLines), CGFloat(minHeight ?? 0) - 2 * DesignTokens.Field.areaVerticalPadding)
    }

    /// Text this tall needs more than `maxLines` lines (half a line of slack for the two text systems' rounding).
    static func overflows(height: CGFloat, maxLines: Int) -> Bool {
        height > lineHeight * (CGFloat(maxLines) + 0.5)
    }

        /// ⌘↩ while the area has the keyboard: a key equivalent, which the window gives out before the text view sees
    /// the key, so Return alone still adds a line.
    @ViewBuilder private var sendKey: some View {
        if let send, focusBinding.wrappedValue, !drawsStill {
            Button("", action: send)
                .keyboardShortcut(.return, modifiers: .command)
                .opacity(0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}
