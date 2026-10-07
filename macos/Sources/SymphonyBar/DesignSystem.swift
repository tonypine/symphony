import AppKit
import SwiftUI
import SymphonyBarCore

// The design system's tokens (`DesignTokens`) mapped to system values, and the components the Symphony window
// shares (`docs/design/design-system.md` §5). Nothing here hardcodes a color.

extension DesignTokens.SystemColor {
    var color: Color {
        switch self {
        case .orange: .orange
        case .blue: .blue
        case .red: .red
        case .green: .green
        case .gray: .gray
        case .purple: .purple
        case .windowBackground: Color(nsColor: .windowBackgroundColor)
        case .contentBackground: Color(nsColor: .controlBackgroundColor)
        case .secondaryBackground: Color(nsColor: .quaternarySystemFill)
        case .separator: Color(nsColor: .separatorColor)
        case .primary: .primary
        case .secondary: .secondary
        case .tertiary: Color(nsColor: .tertiaryLabelColor)
        case .accent: .accentColor
        }
    }
}

extension DesignTokens.Status {
    var tint: Color { color.color }
}

extension DesignTokens.TypeStyle {
    var font: Font {
        switch self {
        case .sentence: .title2.weight(.semibold)
        case .figure: .system(size: 28, weight: .semibold)
        case .section: .title3.weight(.semibold)
        case .rowTitle: .headline
        case .body: .body
        case .callout: .callout
        case .label: .subheadline.weight(.medium)
        case .caption: .caption
        case .mono: .system(.callout, design: .monospaced)
        }
    }
}

extension Animation {
    /// `motion.standard`: sections appearing or leaving, selection.
    static var standard: Animation { .smooth(duration: DesignTokens.Motion.standardDuration) }
}

/// C7: a status's symbol and word in a capsule tinted with its color. The word stays in the primary text color, so
/// contrast never depends on the hue.
struct StatusBadge: View {
    let status: DesignTokens.Status
    var word: String?
    var small = true
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Label {
            Text(word ?? status.word).foregroundStyle(.primary)
        } icon: {
            Image(systemName: status.symbol).foregroundStyle(status.tint)
        }
        .font(small ? DesignTokens.TypeStyle.label.font : DesignTokens.TypeStyle.body.font)
        .labelStyle(.titleAndIcon)
        .padding(.horizontal, DesignTokens.Space.s2)
        .padding(.vertical, DesignTokens.Space.s1 / 2)
        .background(
            status.tint.opacity(DesignTokens.Status.badgeTint(dark: colorScheme == .dark)),
            in: Capsule()
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(word ?? status.word)
    }
}

/// C4: the connection state, quiet while connected; the time of the last update is in its help.
struct ConnectionState: View {
    let state: WindowState
    let lastUpdate: Date?

    var body: some View {
        HStack(spacing: DesignTokens.Space.s1) {
            Circle()
                .fill(state.connectionStatus.tint)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            if let label = state.connectionLabel {
                Text(label).font(DesignTokens.TypeStyle.callout.font).foregroundStyle(.secondary)
            }
        }
        .help(help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state.connectionLabel.map { "Symphony \($0.lowercased())" } ?? "Symphony connected")
    }

    private var help: String {
        guard let lastUpdate else { return state.connectionLabel ?? "Connected" }
        return "Updated \(lastUpdate.formatted(date: .omitted, time: .standard))"
    }
}

/// C10: a titled section on the solid content surface.
struct Card<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s3) {
            Text(title)
                .font(DesignTokens.TypeStyle.section.font)
                .accessibilityAddTraits(.isHeader)
            content
        }
        .padding(DesignTokens.Space.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            DesignTokens.Surface.content.color,
            in: RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous)
                .strokeBorder(DesignTokens.Surface.separator.color)
        )
    }
}

/// C20: a symbol, a sentence and its actions, for an empty or unavailable view.
struct EmptyState: View {
    let title: String
    let symbol: String
    var actions: [(title: String, perform: () -> Void)] = []
    var showsSpinner = false

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            if showsSpinner { ProgressView().controlSize(.small) }
        } actions: {
            ForEach(Array(actions.enumerated()), id: \.offset) { index, action in
                if index == 0 {
                    Button(action.title, action: action.perform).buttonStyle(.borderedProminent)
                } else {
                    Button(action.title, action: action.perform)
                }
            }
        }
    }
}
