import SwiftUI
import SymphonyBarCore

// The Chip's filter form (`.fchip` in `components.css`, the Tickets bar's; TP-1501): one filter set, its words opening
// the filter's menu of values, and its own remove button joined to it at the trailing end.

/// A filter chip: what the filter is (`field`, "Epic is", in the secondary colour) and what it holds (`value`, "Phase
/// 3b", in the primary colour at the label's weight), 24 pt high on the content surface in a strong ring, like the
/// plain `Chip`. A click on the words opens `items`, the filter's values to add or take out, in the app's menu; the
/// joined cross removes the filter. VoiceOver reads the chip as its words, the words as a menu button and the cross as
/// `removeLabel`.
public struct FilterChip: View {
    let field: String
    let value: String
    let removeLabel: String
    var help: String?
    var drawnOpen: Bool
    let items: () -> [MenuItem]
    let remove: () -> Void

    /// `help` is the words' help text. `drawnOpen` draws the menu open under the chip, still, for a snapshot.
    public init(
        _ field: String, value: String, removeLabel: String, help: String? = nil, drawnOpen: Bool = false,
        items: @escaping () -> [MenuItem], remove: @escaping () -> Void
    ) {
        self.field = field
        self.value = value
        self.removeLabel = removeLabel
        self.help = help
        self.drawnOpen = drawnOpen
        self.items = items
        self.remove = remove
    }

    /// What the chip reads: "Epic is Phase 3b".
    public var words: String { "\(field) \(value)" }

    public var body: some View {
        let field = field
        let value = value
        let trigger = MenuTrigger(
            content: .menu(title: words, glyph: nil), size: .small, quiet: false, alignment: .leading, label: words, drawnOpen: drawnOpen,
            face: { state, open in AnyView(FilterChipWords(field: field, value: value, state: state, open: open)) }
        ) { (items(), nil) }
        VStack(alignment: .leading, spacing: DesignTokens.Menu.gap) {
            HStack(spacing: 0) {
                if let help { trigger.help(help) } else { trigger }
                FilterChipRemove(label: removeLabel, action: remove)
            }
            .frame(height: Chip.height)
            .background(Capsule().fill(DesignTokens.Surface.content.color))
            .overlay(Capsule().strokeBorder(DesignTokens.Surface.strong.color, lineWidth: DesignTokens.Control.edgeWidth))
            .fixedSize()
            .accessibilityElement(children: .contain)
            .accessibilityLabel(words)
            if drawnOpen { MenuList(items: items()) }
        }
    }
}

/// The chip's words, lit under the pointer, pressed or open, and in the focus ring while the keyboard is on them.
private struct FilterChipWords: View {
    let field: String
    let value: String
    let state: DesignTokens.Interaction
    let open: Bool

    var body: some View {
        let label = DesignTokens.TypeStyle.label
        let radius = Chip.height / 2
        let shape = UnevenRoundedRectangle(topLeadingRadius: radius, bottomLeadingRadius: radius, style: .continuous)
        (Text(field)
            .font(DesignTokens.TypeStyle.font(size: label.size, weight: DesignTokens.Chip.Filter.fieldWeight))
            .foregroundStyle(DesignTokens.TextColor.secondary.color)
            + Text(" ")
            + Text(value)
            .font(label.font)
            .foregroundStyle(DesignTokens.TextColor.primary.color))
            .lineLimit(1)
            .padding(.leading, DesignTokens.Chip.Filter.leading)
            .padding(.trailing, DesignTokens.Chip.Filter.trailing)
            .frame(height: Chip.height)
            .background {
                if state.pressed || open {
                    shape.fill(DesignTokens.ColorToken.surfacePressed.color)
                } else if state.hovered {
                    shape.fill(DesignTokens.ColorToken.surfaceHover.color)
                }
            }
            .focusRing(state.showsFocusRing, Capsule())
    }
}

/// The joined cross: secondary at rest, primary on the hover fill under the pointer, its trailing end the chip's.
private struct FilterChipRemove: View {
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
        }
        .buttonStyle(FilterChipRemoveStyle())
        .focusEffectDisabled()
        .modifier(ReportsKeyboardFocus())
        .accessibilityLabel(label)
        .help(label)
    }
}

private struct FilterChipRemoveStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Face(configuration: configuration)
    }

    private struct Face: View {
        let configuration: Configuration
        @State private var hovered = false
        @Environment(\.buttonKeyboardFocus) private var keyboardFocus

        var body: some View {
            let radius = Chip.height / 2
            let shape = UnevenRoundedRectangle(bottomTrailingRadius: radius, topTrailingRadius: radius, style: .continuous)
            let lit = hovered || configuration.isPressed
            configuration.label
                .font(DesignTokens.TypeStyle.font(size: DesignTokens.Chip.Filter.removeGlyph, weight: DesignTokens.TypeStyle.label.weight))
                .foregroundStyle((lit ? DesignTokens.TextColor.primary : DesignTokens.TextColor.secondary).color)
                .frame(width: DesignTokens.Chip.Filter.removeWidth, height: Chip.height)
                .background {
                    if configuration.isPressed {
                        shape.fill(DesignTokens.ColorToken.surfacePressed.color)
                    } else if hovered {
                        shape.fill(DesignTokens.ColorToken.surfaceHover.color)
                    }
                }
                .focusRing(keyboardFocus, Capsule())
                .contentShape(shape)
                .onHover { hovered = $0 }
        }
    }
}
