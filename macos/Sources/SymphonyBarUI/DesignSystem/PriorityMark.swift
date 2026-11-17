import SwiftUI
import SymphonyBarCore

/// The catalog's priority mark (`.prio`, TP-1485): a ticket's priority as the forced glyph before its word, in the
/// label style and the forced text colour, on no capsule (unlike `Badge`). It sits on a ticket's identifier line.
/// Its tooltip says what it is; VoiceOver reads "Priority: Urgent".
public struct PriorityMark: View {
    let word: String

    public init(_ word: String) {
        self.word = word
    }

    /// What VoiceOver reads.
    public var accessibilityText: String { "Priority: \(word)" }

    public var body: some View {
        HStack(spacing: DesignTokens.Space.s1) {
            Image(systemName: DesignTokens.Status.forced.symbol)
                .font(DesignTokens.TypeStyle.label.font)
                .foregroundStyle(DesignTokens.Status.forced.tint)
            Text(word)
                .textStyle(.label)
                .foregroundStyle(DesignTokens.Status.forced.text)
                .lineLimit(1)
        }
        .fixedSize()
        .help("Priority")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }
}
