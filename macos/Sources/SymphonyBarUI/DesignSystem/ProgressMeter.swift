import SwiftUI
import SymphonyBarCore

// The catalog's Progress meter (`components/progress-meter`, `.meter`, `.meter-line`; TP-1530): how much of a cap is
// used, tokens against the daily budget, a ticket against its token cap, a provider's window. Drawn rather than a
// `Gauge`, whose AppKit control doesn't render offscreen.

extension ProgressMeterReading.Level {
    /// The fill's colour: the accent, the "waiting on you" orange, the problem red.
    var fill: Color {
        switch self {
        case .calm: DesignTokens.ColorToken.accent.color
        case .near: DesignTokens.Status.you.tint
        case .atCap: DesignTokens.Status.problem.tint
        }
    }

    /// The note's colour: secondary while calm, the level's text colour otherwise.
    var note: Color {
        switch self {
        case .calm: DesignTokens.TextColor.secondary.color
        case .near: DesignTokens.Status.you.text
        case .atCap: DesignTokens.Status.problem.text
        }
    }
}

/// The catalog's Progress meter. The full form (`init(_:)`), 320 pt: the label and the value ("2.1M of 5M tokens ·
/// 42 %") over an 8 pt track, whose fill carries the level (the accent below 75 %, orange from 75 %, red from 95 %)
/// and glows faintly in its colour, and the note under it saying what happens at the cap. The one-line form
/// (`init(line:percent:stop:resets:)`), for several meters read together: the label, a 6 pt track, the percent and
/// when it resets, and no note; a stop mark is a tick where new work stops before the cap, and with one the fill is
/// orange from the mark and red only at 100 %. The fill grows to a new value on a spring. VoiceOver reads a meter:
/// "Tokens today, 42 percent".
public struct ProgressMeter: View {
    enum Form: Equatable {
        case full(ProgressMeterReading)
        case line(label: String, percent: Int, stop: Int?, resets: String?)
    }

    let form: Form
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(_ reading: ProgressMeterReading) {
        form = .full(reading)
    }

    /// The one-line form: `percent` used, a stop mark at `stop` % (none when nil, 0 or 100 and over), and when it
    /// resets in words, after "resets".
    public init(line label: String, percent: Int, stop: Int? = nil, resets: String? = nil) {
        form = .line(label: label, percent: ProgressMeterReading.clamped(percent), stop: ProgressMeterReading.mark(stop), resets: resets)
    }

    /// The share drawn, the fill's level and what VoiceOver reads.
    var percent: Int {
        switch form {
        case let .full(reading): reading.percent
        case let .line(_, percent, _, _): percent
        }
    }

    var level: ProgressMeterReading.Level {
        switch form {
        case let .full(reading): reading.level
        case let .line(_, percent, stop, _): ProgressMeterReading.lineLevel(percent: percent, stop: stop)
        }
    }

    /// Where the stop mark is drawn, if any.
    var stop: Int? {
        if case let .line(_, _, stop, _) = form { return stop }
        return nil
    }

    var spoken: String {
        switch form {
        case let .full(reading): ProgressMeterReading.spoken(reading.label, percent: reading.percent)
        case let .line(label, percent, _, _): ProgressMeterReading.spoken(label, percent: percent)
        }
    }

    public var body: some View {
        Group {
            switch form {
            case let .full(reading): full(reading)
            case let .line(label, percent, stop, resets): line(label, percent: percent, stop: stop, resets: resets)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
        .accessibilityValue("\(percent) percent")
        .animation(.motion(.slow, reduceMotion: reduceMotion), value: percent)
    }

    private func full(_ reading: ProgressMeterReading) -> some View {
        let meter = DesignTokens.ProgressMeter.self
        let level = reading.level
        return VStack(alignment: .leading, spacing: meter.gap) {
            HStack(spacing: DesignTokens.Space.s3) {
                Text(reading.label)
                    .foregroundStyle(DesignTokens.TextColor.secondary.color)
                Spacer(minLength: 0)
                Text(reading.value)
                    .monospacedDigit()
                    .foregroundStyle(DesignTokens.TextColor.primary.color)
                    .contentTransition(.numericText())
            }
            .textStyle(.secondary)
            .lineLimit(1)
            FullTrack(fraction: Double(reading.percent) / 100, level: level)
            Text(reading.note)
                .textStyle(.secondary)
                .foregroundStyle(level.note)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: meter.width, alignment: .leading)
    }

    private func line(_ label: String, percent: Int, stop: Int?, resets: String?) -> some View {
        let meter = DesignTokens.ProgressMeter.self
        return HStack(spacing: meter.lineGap) {
            Text(label)
                .textStyle(.body)
                .foregroundStyle(DesignTokens.TextColor.secondary.color)
                .lineLimit(1)
                .frame(width: meter.lineLabel, alignment: .leading)
            LineTrack(fraction: Double(percent) / 100, stop: stop, level: ProgressMeterReading.lineLevel(percent: percent, stop: stop))
                .frame(minWidth: meter.lineTrackMin, maxWidth: .infinity)
            Text("\(percent) %")
                .font(DesignTokens.TypeStyle.font(size: DesignTokens.TypeStyle.body.size, weight: 600))
                .monospacedDigit()
                .foregroundStyle(DesignTokens.TextColor.primary.color)
                .lineLimit(1)
                .frame(width: meter.lineValue, alignment: .trailing)
            Text(resets.map { "resets \($0)" } ?? "")
                .textStyle(.secondary)
                .foregroundStyle(DesignTokens.TextColor.secondary.color)
                .lineLimit(1)
                .frame(width: meter.lineResets, alignment: .leading)
        }
    }
}

/// The full form's track: a capsule of the fill's colour at 14 % over the sunken surface, sunk by a soft inner
/// shadow, and the fill from its colour lightened to it, glowing faintly.
private struct FullTrack: View {
    let fraction: Double
    let level: ProgressMeterReading.Level

    var body: some View {
        let meter = DesignTokens.ProgressMeter.self
        let fill = level.fill
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(
                        DesignTokens.Surface.sunken.color.mix(with: fill, by: meter.trackTint)
                            .shadow(.inner(color: DesignTokens.ColorToken.shadowNear.color, radius: 1, y: 1))
                    )
                if fraction > 0 {
                    Capsule()
                        .fill(LinearGradient(colors: [fill.mix(with: .white, by: meter.fillLight), fill], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(proxy.size.width * fraction, proxy.size.height))
                        .shadow(color: fill.opacity(meter.glowOpacity), radius: meter.glowRadius)
                }
            }
        }
        .frame(height: meter.trackHeight)
        .accessibilityHidden(true)
    }
}

/// The one-line form's track: 6 pt on the pressed surface, the fill in its colour, and the stop mark, a 2 pt tick
/// in the secondary colour reaching 4 pt past the track above and below.
private struct LineTrack: View {
    let fraction: Double
    let stop: Int?
    let level: ProgressMeterReading.Level

    var body: some View {
        let meter = DesignTokens.ProgressMeter.self
        let radius = meter.lineTrackHeight / 2
        // The track and fill keep the track's height on their own, and the tick is an overlay: inside one ZStack the
        // 14 pt tick would set the stack's height and the flexible track and fill would grow to it.
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: radius)
                    .fill(DesignTokens.ColorToken.surfacePressed.color)
                    .frame(width: proxy.size.width, height: meter.lineTrackHeight)
                if fraction > 0 {
                    RoundedRectangle(cornerRadius: radius)
                        .fill(level.fill)
                        .frame(width: proxy.size.width * fraction, height: meter.lineTrackHeight)
                }
            }
            .frame(width: proxy.size.width, height: meter.lineTrackHeight, alignment: .leading)
            .overlay(alignment: .leading) {
                if let stop {
                    RoundedRectangle(cornerRadius: meter.stopWidth / 2)
                        .fill(DesignTokens.TextColor.secondary.color)
                        .frame(width: meter.stopWidth, height: meter.lineTrackHeight + 2 * meter.stopReach)
                        .offset(x: proxy.size.width * Double(stop) / 100 - meter.stopWidth / 2)
                        .help("New runs stop at \(stop) %")
                }
            }
        }
        .frame(height: meter.lineTrackHeight)
        .accessibilityHidden(true)
    }
}
