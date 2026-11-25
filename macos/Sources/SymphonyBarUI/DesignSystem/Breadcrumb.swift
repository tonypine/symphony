import SwiftUI
import SymphonyBarCore

// The catalog's breadcrumb (`.win-crumbs` in `winToolbar`, TP-1496): where the window is, in the window bar.

/// Where the window is: each part but the last a link to its place, a 10 pt chevron between them, and the last part,
/// where the window is, in the row title's weight with its digits tabular ("Work › Phase 3b › TP-1382"). The links are
/// in the secondary text colour and turn primary under the pointer; they take the keyboard in order. VoiceOver reads it
/// as one group, "Where you are", with each link a link.
public struct Breadcrumb: View {
    let crumbs: [Crumb]
    let go: (Crumb) -> Void
    /// Draws the link at this index under the pointer, for the gallery.
    var hovered: Int?

    public init(_ breadcrumb: WindowBreadcrumb, hovered: Int? = nil, go: @escaping (Crumb) -> Void) {
        crumbs = breadcrumb.crumbs
        self.hovered = hovered
        self.go = go
    }

    public var body: some View {
        let tokens = DesignTokens.Breadcrumb.self
        HStack(spacing: tokens.gap) {
            ForEach(Array(crumbs.enumerated()), id: \.offset) { index, crumb in
                if index > 0 {
                    Image(systemName: tokens.chevronSymbol)
                        .font(DesignTokens.TypeStyle.font(size: tokens.chevron, weight: 600))
                        .foregroundStyle(DesignTokens.TextColor.tertiary.color)
                        .accessibilityHidden(true)
                }
                if index == crumbs.count - 1 || crumb.target == nil {
                    Text(crumb.title)
                        .font(DesignTokens.TypeStyle.rowTitle.font)
                        .monospacedDigit()
                        .foregroundStyle(DesignTokens.TextColor.primary.color)
                        .lineLimit(1)
                        .fixedSize()
                        .help(crumb.help ?? crumb.title)
                        .accessibilityLabel(crumb.help ?? crumb.title)
                } else {
                    Button { go(crumb) } label: {
                        CrumbLabel(crumb: crumb)
                    }
                    .buttonStyle(CrumbStyle(hovered: hovered == index))
                    .focusEffectDisabled()
                    .modifier(ReportsKeyboardFocus())
                    .help(crumb.help ?? crumb.title)
                    .accessibilityLabel(crumb.help ?? crumb.title)
                    .accessibilityAddTraits(.isLink)
                    .accessibilityRemoveTraits(.isButton)
                }
            }
        }
        .lineLimit(1)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(WindowBreadcrumb.accessibilityLabel)
    }
}

/// A link's words, with its glyph before them when it has one.
private struct CrumbLabel: View {
    let crumb: Crumb

    var body: some View {
        let tokens = DesignTokens.Breadcrumb.self
        HStack(spacing: tokens.glyphGap) {
            if let symbol = crumb.symbol {
                Image(systemName: symbol)
                    .font(DesignTokens.TypeStyle.font(size: tokens.glyph, weight: DesignTokens.TypeStyle.secondary.weight))
            }
            Text(crumb.title)
                .font(DesignTokens.TypeStyle.secondary.font)
        }
        .fixedSize()
    }
}

/// A link of the breadcrumb: secondary at rest, primary under the pointer, pressed or focused, with the focus ring.
private struct CrumbStyle: ButtonStyle {
    var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        Face(configuration: configuration, drawnHovered: hovered)
    }

    private struct Face: View {
        let configuration: Configuration
        let drawnHovered: Bool
        @State private var hovered = false
        @Environment(\.buttonKeyboardFocus) private var keyboardFocus

        var body: some View {
            let lit = drawnHovered || hovered || configuration.isPressed || keyboardFocus
            configuration.label
                .foregroundStyle((lit ? DesignTokens.TextColor.primary : DesignTokens.TextColor.secondary).color)
                .contentShape(Rectangle())
                .focusRing(keyboardFocus, RoundedRectangle(cornerRadius: DesignTokens.Breadcrumb.radius, style: .continuous))
                .onHover { hovered = $0 }
                .buttonPointer()
        }
    }
}
