import SwiftUI
import SymphonyBarCore

extension EnvironmentValues {
    /// Whether a duration so far counts on as the clock moves: the window's ticket page. A snapshot's stays at its
    /// model's reference, so it draws the same each time.
    @Entry public var liveDurations = false
    /// The moment the timeline's durations so far count to, set by the Timeline section from its model.
    @Entry var timelineReference: Date?
}

/// A duration so far that counts on from `reference` by itself, every `LiveDurationText.interval`, while the page
/// model stays as it was built (TP-1479): only this text draws again. Without `reference`, or outside the window's
/// page, it shows `seconds` as they are.
struct LiveDurationText: View {
    let seconds: Int
    /// When `seconds` were measured; nil for a duration that no longer runs.
    let reference: Date?
    let text: (Int) -> String
    @Environment(\.liveDurations) private var live

    static let interval: TimeInterval = 30

    var body: some View {
        if live, let reference {
            TimelineView(.periodic(from: .now, by: Self.interval)) { context in
                Text(text(Self.seconds(seconds, reference: reference, at: context.date)))
            }
        } else {
            Text(text(seconds))
        }
    }

    /// `seconds` measured at `reference`, counted on to `date`; never back.
    static func seconds(_ seconds: Int, reference: Date, at date: Date) -> Int {
        seconds + max(Int(date.timeIntervalSince(reference)), 0)
    }
}
