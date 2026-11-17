import SwiftUI
import SymphonyBarCore

// The catalog's List card (`components/list-card`, `.list-card`; TP-1530): one thing in the list beside its page,
// such as a provider in Factory › Providers.

/// What a List card says: its name, the one fact the Director compares across the list (none is drawn when empty),
/// and where it stands, a Status dot (live when something is working) and the short form of the page's Situation line.
public struct ListCardContent: Equatable {
    public var title: String
    public var fact: String?
    public var status: DesignTokens.Status
    public var statusLine: String
    public var live: Bool

    public init(title: String, fact: String? = nil, status: DesignTokens.Status, statusLine: String, live: Bool = false) {
        self.title = title
        self.fact = fact
        self.status = status
        self.statusLine = statusLine
        self.live = live
    }

    /// The fact drawn: none when it is empty.
    var shownFact: String? { fact.flatMap { $0.isEmpty ? nil : $0 } }

    /// What VoiceOver reads: "Anthropic, 62 % of the week, 3 working".
    public var spoken: String { [title, shownFact, statusLine].compactMap { $0 }.joined(separator: ", ") }
}

/// One state of a List card: the card surface at the first elevation; under the pointer it lifts a point onto the
/// second; selected it carries the accent edge and its tint ring, grey while the window is not focused
/// (`windowFocused`); keyboard focus draws the focus ring.
public struct ListCardFace: View {
    let content: ListCardContent
    let state: DesignTokens.Interaction
    let windowFocused: Bool
    let reduceMotion: Bool

    public init(_ content: ListCardContent, state: DesignTokens.Interaction = .rest, windowFocused: Bool = true, reduceMotion: Bool) {
        self.content = content
        self.state = state
        self.windowFocused = windowFocused
        self.reduceMotion = reduceMotion
    }

    public var body: some View {
        let card = DesignTokens.ListCard.self
        let shape = RoundedRectangle(cornerRadius: card.radius, style: .continuous)
        let raised = state.hovered && !state.disabled
        VStack(alignment: .leading, spacing: card.gap) {
            HStack(alignment: .firstTextBaseline, spacing: card.topGap) {
                Text(content.title)
                    .textStyle(.rowTitle)
                    .monospacedDigit()
                    .foregroundStyle(DesignTokens.TextColor.primary.color)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let fact = content.shownFact {
                    Text(fact)
                        .textStyle(.secondary)
                        .monospacedDigit()
                        .foregroundStyle(DesignTokens.TextColor.secondary.color)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            HStack(spacing: card.dotGap) {
                StatusDot(content.status, diameter: card.dot, live: content.live)
                Text(content.statusLine)
                    .textStyle(.secondary)
                    .foregroundStyle(DesignTokens.TextColor.secondary.color)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, card.verticalPadding)
        .padding(.horizontal, card.horizontalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.Surface.content.color, in: shape)
        .edgeHighlight(shape)
        .elevation(raised ? .level2 : .level1, in: shape)
        .overlay {
            if state.showsSelectionRing {
                shape.strokeBorder((windowFocused ? DesignTokens.ColorToken.accent : DesignTokens.Surface.strong).color, lineWidth: card.ringWidth)
                    .allowsHitTesting(false)
            }
        }
        .overlay {
            if state.showsSelectionRing, windowFocused {
                shape.inset(by: -card.tintWidth / 2).stroke(DesignTokens.ColorToken.accentTint.color, lineWidth: card.tintWidth)
                    .allowsHitTesting(false)
            }
        }
        .focusRing(state.showsFocusRing, shape)
        .offset(y: -DesignTokens.Motion.lift(hovered: raised, reduceMotion: reduceMotion))
        .animation(.motion(.lift, reduceMotion: reduceMotion), value: state)
        .animation(.motion(.lift, reduceMotion: reduceMotion), value: windowFocused)
    }
}

/// The catalog's List card: one thing in the list beside its page, its name, one fact and where it stands. A click
/// picks it (`action`); the list it sits in is a listbox whose arrows move the selection, and the page follows it.
/// VoiceOver reads its name, its fact and its status line, and whether it is selected.
public struct ListCard: View {
    let content: ListCardContent
    let selected: Bool
    let action: () -> Void

    public init(_ content: ListCardContent, selected: Bool = false, action: @escaping () -> Void) {
        self.content = content
        self.selected = selected
        self.action = action
    }

    public var body: some View {
        Button(action: action) { Text(content.title) }
            .buttonStyle(ListCardStyle(content: content, selected: selected))
            .focusEffectDisabled()
            .modifier(ListCardFocus())
            .accessibilityLabel(content.spoken)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The live card: the pointer, keyboard focus, and whether its window is the key one.
private struct ListCardStyle: ButtonStyle {
    let content: ListCardContent
    let selected: Bool

    func makeBody(configuration _: Configuration) -> some View {
        Face(content: content, selected: selected)
    }

    private struct Face: View {
        let content: ListCardContent
        let selected: Bool
        @State private var hovered = false
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.buttonKeyboardFocus) private var keyboardFocus
        @Environment(\.appearsActive) private var appearsActive
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            ListCardFace(
                content,
                state: DesignTokens.Interaction(hovered: hovered, selected: selected, focused: keyboardFocus, disabled: !isEnabled),
                windowFocused: appearsActive, reduceMotion: reduceMotion
            )
            .contentShape(RoundedRectangle(cornerRadius: DesignTokens.ListCard.radius, style: .continuous))
            .onHover { hovered = $0 }
        }
    }
}

/// Hands the card's own keyboard focus to its face, as the shared button does.
private struct ListCardFocus: ViewModifier {
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content.environment(\.buttonKeyboardFocus, focused).focused($focused)
    }
}
