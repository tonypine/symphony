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
            DoneTrack(fraction: queue.checksFraction(proved: proved, total: total))
                .frame(maxWidth: queue.checksTrackWidth)
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

/// The bar of a share done (`.cbar i`): a 3 pt track on the pressed surface, filled in the done colour to `fraction`.
/// `track` draws the track in another surface (the epic band's done count, lifted).
struct DoneTrack: View {
    let fraction: Double
    var track: Color = DesignTokens.StateSurface.pressed.fill

    var body: some View {
        Capsule()
            .fill(track)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule()
                        .fill(DesignTokens.Status.done.tint)
                        .frame(width: proxy.size.width * min(max(fraction, 0), 1))
                }
            }
            .clipShape(Capsule())
            .frame(height: DesignTokens.HomeQueue.checksTrackHeight)
            .accessibilityHidden(true)
    }
}
