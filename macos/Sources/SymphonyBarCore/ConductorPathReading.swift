import Foundation

/// The Run path's one line, read off a path block: the last stop that ended, the stop the ticket is at and the next one
/// to come, with everything before them folded into a leading count and everything after into a trailing count. The
/// path never wraps, so what it shows is always these three and two counts.
public struct ConductorPathReading: Equatable {
    public typealias Stop = ConductorBlock.Path.Stop

    /// The last stop that ended (done or failed), just before the current one.
    public var lastEnded: Stop?
    public var current: Stop?
    public var next: Stop?
    /// The stops folded into the leading count, oldest first.
    public var earlier: [Stop]
    /// The stops folded into the trailing count.
    public var later: [Stop]
    /// "N loops through QA and rework · 3 h 12 min": under the line, only when the ticket looped.
    public var loopsLine: String?
    /// Every stop, in order, for the help and VoiceOver.
    public var all: [Stop]

    public init(_ path: ConductorBlock.Path) {
        let stops = path.stops
        all = stops
        let currentIndex = stops.firstIndex { $0.state == .current }
        let endedIndex: Int?
        let nextIndex: Int?
        if let currentIndex {
            endedIndex = currentIndex > 0 ? currentIndex - 1 : nil
            nextIndex = currentIndex + 1 < stops.count ? currentIndex + 1 : nil
        } else {
            endedIndex = stops.lastIndex { $0.state == .done || $0.state == .failed }
            nextIndex = stops.firstIndex { $0.state == .upcoming }
        }
        let shown = [endedIndex, currentIndex, nextIndex].compactMap { $0 }
        lastEnded = endedIndex.map { stops[$0] }
        current = currentIndex.map { stops[$0] }
        next = nextIndex.map { stops[$0] }
        let first = shown.min() ?? stops.count
        earlier = Array(stops[..<first])
        later = stops.indices.filter { $0 > first && !shown.contains($0) }.map { stops[$0] }
        loopsLine = path.loops > 0
            ? "\(path.loops) \(path.loops == 1 ? "loop" : "loops") through QA and rework"
                + (path.elapsedMs.map { " · " + Overview.duration($0 / 1_000) } ?? "")
            : nil
    }

    /// Any of the earlier stops failed: the leading count is in the problem colour.
    public var earlierFailed: Bool { earlier.contains { $0.state == .failed } }

    /// "✓ 2 earlier", or "2 earlier" when one of them failed; nil when none is folded.
    public var earlierText: String? {
        guard !earlier.isEmpty else { return nil }
        return (earlierFailed ? "" : "✓ ") + "\(earlier.count) earlier"
    }

    /// "+1"; nil when none is folded.
    public var laterText: String? { later.isEmpty ? nil : "+\(later.count)" }

    /// A stop's name with how many times the ticket met it and, for the current one, its run: "QA ×2", "Rework · run 2".
    public static func name(_ stop: Stop) -> String {
        var name = stop.phase
        if stop.times > 1 { name += " ×\(stop.times)" }
        if stop.state == .current, let run = stop.runNumber { name += " · run \(run)" }
        return name
    }

    /// The folded stops, for the help under the pointer; nil when nothing is folded.
    public var help: String? {
        var lines: [String] = []
        if !earlier.isEmpty { lines.append("Earlier: " + earlier.map(Self.described).joined(separator: ", ")) }
        if !later.isEmpty { lines.append("Later: " + later.map(Self.described).joined(separator: ", ")) }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// "QA ×2, failed", "Coding, done".
    static func described(_ stop: Stop) -> String { name(stop) + ", " + stop.state.rawValue }

    /// The path for VoiceOver, every stop in order, folded or not.
    public var accessibilityLabel: String {
        "Run path: " + all.map(Self.described).joined(separator: "; ") + (loopsLine.map { ". " + $0 } ?? "")
    }
}
