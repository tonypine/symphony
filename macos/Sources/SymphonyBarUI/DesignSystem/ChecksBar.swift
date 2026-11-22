import SwiftUI
import SymphonyBarCore

// The Home queue's checks bar (TP-1608, `.cbar` in `docs/design/prototypes/home-queue/page.css`): how many of a
// plan's checks are proved, as a short bar in the done colour and its words, "5 of 9 checks proved".

public struct ChecksBar: View {
    let proved: Int
    let total: Int

    public init(proved: Int, total: Int) {
        self.proved = proved
        self.total = total
    }

    /// "5 of 9 checks proved".
    public var text: String { DesignTokens.HomeQueue.checks(proved: proved, total: total) }

    public var body: some View {
        let queue = DesignTokens.HomeQueue.self
        HStack(spacing: queue.checksGap) {
            Capsule()
                .fill(DesignTokens.StateSurface.pressed.fill)
                .overlay(alignment: .leading) {
                    GeometryReader { proxy in
                        Capsule()
                            .fill(DesignTokens.Status.done.tint)
                            .frame(width: proxy.size.width * queue.checksFraction(proved: proved, total: total))
                    }
                }
                .clipShape(Capsule())
                .frame(maxWidth: queue.checksTrackWidth)
                .frame(height: queue.checksTrackHeight)
            Text(text)
                .textStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(DesignTokens.TextColor.secondary.color)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}
