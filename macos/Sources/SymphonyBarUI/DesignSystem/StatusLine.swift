import SwiftUI
import SymphonyBarCore

// The catalog's status line (`.win-status`, `.dispatch`, `winStatus` and `dispatchControl` in
// `docs/design/catalog/stories.js`, TP-1498): the line of glass under the page, drawn from `DesignTokens.StatusLine`.

/// The window's status line: 30 pt of glass under the page with a hairline over it. The dispatch control it is given,
/// then, when Home's read is there, a hairline and what is in progress, in the queue and needs the Director; at the
/// right the build that answers and the connection with its dot. VoiceOver reads the line as one group, labelled with
/// all of it, and the control inside it. While Symphony is late (TP-1562) the counts are its last answer's, in the
/// tertiary colour, and the line offers Open Logs and Restart Symphony after the connection.
public struct StatusLine<Dispatch: View>: View {
    let line: HealthLine
    let dispatch: Dispatch
    let onAction: (WindowState.Action) -> Void

    public init(
        _ line: HealthLine, onAction: @escaping (WindowState.Action) -> Void = { _ in }, @ViewBuilder dispatch: () -> Dispatch
    ) {
        self.line = line
        self.onAction = onAction
        self.dispatch = dispatch()
    }

    public var body: some View {
        let tokens = DesignTokens.StatusLine.self
        HStack(spacing: tokens.gap) {
            dispatch
                .fixedSize()
            if let counts = line.counts {
                // The counts yield first when the line runs out of room (TP-1562: the late line adds Open Logs and
                // Restart Symphony): the last ones drop whole, so the dispatch control and the build stay readable.
                ViewThatFits(in: .horizontal) {
                    ForEach(Array(stride(from: counts.texts.count, to: 0, by: -1)), id: \.self) { shown in
                        countsView(Array(counts.texts.prefix(shown)))
                    }
                    Color.clear.frame(width: 0, height: 0)
                }
                .layoutPriority(1)
            }
            Spacer(minLength: 0)
            if let build = line.build {
                Text(build.text)
                    .monospacedDigit()
                    .truncationMode(.middle)
                    .foregroundStyle(tokens.build.color)
                    .help(build.help ?? build.text)
                    .layoutPriority(2)
            }
            HStack(spacing: tokens.dotGap) {
                if let status = line.connection.status { StatusDot(status) }
                Text(line.connection.text)
            }
            .fixedSize()
            .help(line.connection.help ?? line.connection.text)
            ForEach(line.actions, id: \.title) { action in
                Button(action.title) { onAction(action) }
                    .directorButton(.quiet, size: .small)
                    .fixedSize()
            }
        }
        .textStyle(.secondary)
        .foregroundStyle(DesignTokens.TextColor.secondary.color)
        .lineLimit(1)
        .padding(.leading, tokens.leadingPadding)
        .padding(.trailing, tokens.trailingPadding)
        .frame(maxWidth: .infinity)
        .frame(height: tokens.height)
        .background { BarGlass(tokens.glass) }
        .overlay(alignment: .top) { HairlineDivider() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(line.accessibilityLabel)
    }

    /// The hairline and `texts`, Home's counts, in the tertiary colour while they are Symphony's last answer.
    private func countsView(_ texts: [String]) -> some View {
        let tokens = DesignTokens.StatusLine.self
        return HStack(spacing: tokens.gap) {
            HairlineDivider(.vertical, length: tokens.separatorHeight)
                .padding(.horizontal, tokens.separatorInset)
            ForEach(texts, id: \.self) { text in
                Text(text).monospacedDigit()
                    .foregroundStyle((line.countsCurrent ? DesignTokens.TextColor.secondary : DesignTokens.TextColor.tertiary).color)
            }
        }
        .fixedSize()
    }
}

/// The status line's dispatch control (`.dispatch`): a status dot, pulsing while dispatch is on and orange while it is
/// paused, "Dispatch on" or "Dispatch paused" (or why it holds, or Symphony's state), and a chevron for its menu;
/// "Start Symphony" in place of the chevron while Symphony is stopped. Quiet at rest, the hover surface under the
/// pointer, pressed while held or while its menu is `open`. `drawnAs` draws one state still, for the gallery.
public struct DispatchStatusControl: View {
    let control: DispatchControl
    let open: Bool
    let drawnAs: DesignTokens.Interaction?
    let action: () -> Void
    @State private var hovered = false
    @FocusState private var focused: Bool

    public init(_ control: DispatchControl, open: Bool = false, drawnAs: DesignTokens.Interaction? = nil, action: @escaping () -> Void) {
        self.control = control
        self.open = open
        self.drawnAs = drawnAs
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Text(control.lineWord)
        }
        .buttonStyle(DispatchStatusStyle(control: control, open: open, hovered: hovered, focused: focused, drawnAs: drawnAs))
        .focusEffectDisabled()
        .focused($focused)
        .onHover { hovered = $0 }
        .help(control.canStart ? DispatchControl.startTitle : control.word)
        .accessibilityLabel(control.accessibilityLabel)
    }
}

/// The dispatch control's face in each of its states.
private struct DispatchStatusStyle: ButtonStyle {
    let control: DispatchControl
    let open: Bool
    let hovered: Bool
    let focused: Bool
    let drawnAs: DesignTokens.Interaction?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let tokens = DesignTokens.StatusLine.Dispatch.self
        let state = drawnAs ?? DesignTokens.Interaction(hovered: hovered, pressed: configuration.isPressed, focused: focused)
        let shape = RoundedRectangle(cornerRadius: tokens.control.radius, style: .continuous)
        return HStack(spacing: tokens.gap) {
            StatusDot(control.status, live: control.live)
            Text(control.lineWord)
                .font(DesignTokens.TypeStyle.font(size: tokens.textSize, weight: tokens.weight))
                .foregroundStyle(DesignTokens.TextColor.primary.color)
                .lineLimit(1)
            if control.canStart {
                Text(DispatchControl.startTitle)
                    .font(DesignTokens.TypeStyle.font(size: tokens.textSize, weight: tokens.weight))
                    .foregroundStyle(DesignTokens.ColorToken.accentText.color)
                    .lineLimit(1)
            } else {
                Image(systemName: tokens.chevronSymbol)
                    .resizable()
                    .scaledToFit()
                    .frame(width: tokens.chevron, height: tokens.chevron)
                    .foregroundStyle(DesignTokens.TextColor.secondary.color)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, tokens.inset)
        .frame(height: tokens.control.height)
        .background {
            if let fill = tokens.fill(state, open: open) { shape.fill(fill.color) }
        }
        .focusRing(state.showsFocusRing, shape)
        .scaleEffect(DesignTokens.Motion.scale(DesignTokens.Motion.pressScale, pressed: state.pressed, reduceMotion: reduceMotion))
        .contentShape(shape)
        .animation(.motion(.fast, reduceMotion: reduceMotion), value: state)
    }
}
