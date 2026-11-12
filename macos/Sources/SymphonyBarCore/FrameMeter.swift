import Foundation

/// Counts late frames from a display link's ticks, for the ticket page scroll test (TP-1491). Each tick is the time a
/// frame was shown; a gap between two ticks longer than one frame and a half means the main thread, which the link
/// ticks on, was busy past a frame and the frames in between were not drawn. The time past one frame is hitch time
/// (Apple's measure: milliseconds a frame came late), and the frames that fit in the gap but never came are dropped.
public struct FrameMeter: Equatable {
    /// What a measurement found, written to the QA root as `frames.json`.
    public struct Summary: Codable, Equatable {
        /// The ticks counted.
        public var frames: Int
        /// From the first tick to the last.
        public var seconds: Double
        /// One frame at the display's rate.
        public var frameMs: Double
        /// The time frames came late, in all.
        public var hitchMs: Double
        /// Frames the gaps held that were never drawn.
        public var dropped: Int
        /// The longest gap between two ticks.
        public var longestMs: Double
        /// Milliseconds of hitch per second measured; 0 for a measurement shorter than one frame.
        public var hitchRatio: Double

        public init(frames: Int, seconds: Double, frameMs: Double, hitchMs: Double, dropped: Int, longestMs: Double) {
            self.frames = frames
            self.seconds = seconds
            self.frameMs = frameMs
            self.hitchMs = hitchMs
            self.dropped = dropped
            self.longestMs = longestMs
            hitchRatio = seconds > 0 ? hitchMs / seconds : 0
        }

        enum CodingKeys: String, CodingKey {
            case frames, seconds, dropped
            case frameMs = "frame_ms"
            case hitchMs = "hitch_ms"
            case longestMs = "longest_ms"
            case hitchRatio = "hitch_ratio"
        }
    }

    /// The file name of the summary under the QA root.
    public static let fileName = "frames.json"
    /// A gap longer than this many frames is a hitch.
    static let hitchThreshold = 1.5
    /// The frame used until a tick says the display's own: 60 Hz.
    static let defaultFrame: TimeInterval = 1.0 / 60

    public private(set) var frame: TimeInterval = FrameMeter.defaultFrame
    private var first: TimeInterval?
    private var last: TimeInterval?
    private var frames = 0
    private var hitch: TimeInterval = 0
    private var dropped = 0
    private var longest: TimeInterval = 0

    public init() {}

    /// Counts the tick of a frame shown at `timestamp`, on a display whose frames last `frame` (the link's
    /// `targetTimestamp - timestamp`; a value that is not positive keeps the last one).
    public mutating func record(_ timestamp: TimeInterval, frame: TimeInterval) {
        if frame > 0 { self.frame = frame }
        frames += 1
        defer { last = timestamp }
        guard let last else {
            first = timestamp
            return
        }
        let gap = timestamp - last
        longest = max(longest, gap)
        guard gap > self.frame * Self.hitchThreshold else { return }
        hitch += gap - self.frame
        dropped += max(0, Int((gap / self.frame).rounded()) - 1)
    }

    public var summary: Summary {
        let seconds = first.flatMap { first in last.map { $0 - first } } ?? 0
        return Summary(
            frames: frames,
            seconds: seconds,
            frameMs: frame * 1000,
            hitchMs: hitch * 1000,
            dropped: dropped,
            longestMs: longest * 1000
        )
    }

    /// The summary as `frames.json` holds it.
    public func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(summary)
    }
}
