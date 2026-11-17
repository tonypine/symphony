import Foundation

/// What the catalog's Progress meter (TP-1530) reads off a use against its cap: the share used, its level (the
/// fill's colour) and, in the full form, the value and the note under the track. The one-line form has a stop mark
/// where new work stops before the cap: with one, the fill is orange from the mark and red only at 100 %.
public struct ProgressMeterReading: Equatable {
    /// What the cap counts.
    public enum Unit: String, CaseIterable, Equatable {
        case tokens, runs
    }

    /// The fill's colour: the accent while calm, the "waiting on you" orange near the cap, the problem red at it.
    public enum Level: String, CaseIterable, Equatable {
        case calm, near, atCap
    }

    public var label: String
    public var used: Double
    public var cap: Double
    public var unit: Unit
    /// When the use starts again from nothing ("at midnight"), in words.
    public var resets: String

    public init(label: String, used: Double, cap: Double, unit: Unit = .tokens, resets: String) {
        self.label = label
        self.used = used
        self.cap = cap
        self.unit = unit
        self.resets = resets
    }

    /// The share used, a whole percent from 0 to 100.
    public var percent: Int { Self.percent(used: used, cap: cap) }

    public var level: Level { Self.level(percent: percent) }

    /// "2.1M of 5M tokens · 42 %".
    public var value: String { "\(Self.amount(used, unit: unit)) of \(Self.amount(cap, unit: unit)) \(unit.rawValue) · \(percent) %" }

    /// What happens as the use nears its cap, in words.
    public var note: String {
        let percent = percent
        if percent >= 100 { return "At the cap: no new run starts until \(resets)." }
        if percent >= DesignTokens.ProgressMeter.atCap { return "Almost at the cap: runs still finish, new ones wait from 100 %." }
        if percent >= DesignTokens.ProgressMeter.near { return "Getting close: \(100 - percent) % left until \(resets)." }
        return "Plenty left. Resets \(resets)."
    }

    /// What VoiceOver reads: "Tokens today, 42 percent".
    public static func spoken(_ label: String, percent: Int) -> String { "\(label), \(percent) percent" }

    /// `used` of `cap` as a whole percent, rounded, from 0 to 100; a cap under 1 counts as 1.
    public static func percent(used: Double, cap: Double) -> Int {
        let share = max(0, used) / max(1, cap) * 100
        return min(100, Int(share.rounded()))
    }

    /// The full form's level: orange from 75 %, red from 95 %.
    public static func level(percent: Int) -> Level {
        if percent >= DesignTokens.ProgressMeter.atCap { return .atCap }
        if percent >= DesignTokens.ProgressMeter.near { return .near }
        return .calm
    }

    /// The one-line form's level: without a stop mark as the full form; with one at `stop` %, orange from the mark
    /// and red only at 100 %.
    public static func lineLevel(percent: Int, stop: Int?) -> Level {
        guard let stop = mark(stop) else { return level(percent: percent) }
        if percent >= 100 { return .atCap }
        return percent >= stop ? .near : .calm
    }

    /// The stop mark drawn for `stop`: none for nil, 0 or under, or 100 and over (the cap is its own end).
    public static func mark(_ stop: Int?) -> Int? {
        guard let stop, stop > 0, stop < 100 else { return nil }
        return stop
    }

    /// The share clamped to 0...100, for the one-line form given a percent.
    public static func clamped(_ percent: Int) -> Int { min(100, max(0, percent)) }

    /// A count as the meter says it: tokens in millions ("2.1M", "5M") and thousands ("12K"), runs as they are.
    public static func amount(_ value: Double, unit: Unit) -> String {
        let whole = Int(value.rounded())
        guard unit == .tokens else { return String(whole) }
        if value >= 1_000_000 {
            let millions = String(format: "%.1f", value / 1_000_000)
            return (millions.hasSuffix(".0") ? String(millions.dropLast(2)) : millions) + "M"
        }
        if value >= 1000 { return "\(Int((value / 1000).rounded()))K" }
        return String(whole)
    }
}
