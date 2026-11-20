import Foundation

extension ConductorJunction {
    /// The junction in words, after the Conductor's name on the timeline: "after QA failed".
    public var words: String {
        switch self {
        case .afterCoding: "after coding"
        case .afterQAFail: "after QA failed"
        case .afterQABlocked: "after QA was blocked"
        case .afterRework: "after rework"
        case .beforeMerge: "before merge"
        }
    }
}

/// What a `conductor.update` says about the run it watched: the `watch` map of its payload. A turn the Conductor took
/// at a junction has none. Every field is optional, and a field of another type reads as missing.
public struct ConductorWatch: Decodable, Equatable {
    /// The run the Conductor watched, not the Conductor's own.
    public var runID: String?
    /// Why the Conductor looked: the event that made it.
    public var trigger: String?
    /// It sent the run guidance.
    public var steered: Bool
    /// When the guidance reaches the run: "next_turn" or "now"; nil when it sent none.
    public var when: String?
    /// It stopped the run.
    public var stopped: Bool

    enum CodingKeys: String, CodingKey {
        case runId, runIdAsWritten = "run_id", trigger, steered, when, stopped
    }

    public init(runID: String? = nil, trigger: String? = nil, steered: Bool = false, when: String? = nil, stopped: Bool = false) {
        self.runID = runID
        self.trigger = trigger
        self.steered = steered
        self.when = when
        self.stopped = stopped
    }

    public init(from decoder: Decoder) throws {
        // Only a map is a watch; each of its fields is read on its own, and one of another type is missing.
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func text(_ key: CodingKeys) -> String? { (try? container.decodeIfPresent(String.self, forKey: key)) ?? nil }
        func flag(_ key: CodingKeys) -> Bool { ((try? container.decodeIfPresent(Bool.self, forKey: key)) ?? nil) ?? false }
        self.init(runID: (text(.runId) ?? text(.runIdAsWritten)).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }, trigger: text(.trigger), steered: flag(.steered), when: text(.when), stopped: flag(.stopped))
    }

    /// The Conductor acted on the run: it steered or stopped it. Otherwise it looked and left the run alone.
    public var acted: Bool { steered || stopped }

    /// "steered this run", "stopped this run"; nil when it left the run alone.
    public var action: String? {
        if stopped { return "stopped this run" }
        return steered ? "steered this run" : nil
    }

    /// "at its next turn", "now"; nil when it says neither.
    public var timing: String? {
        switch when {
        case "next_turn": "at its next turn"
        case "now": "now"
        default: nil
        }
    }
}

/// The Conductor speaking to a person (`conductor.update`): its words, when, and where it spoke from. At a junction it
/// is a message on the timeline; while it watched a run it is a note inside that run's group.
public struct ConductorMessage: Equatable, Identifiable {
    public var id: String
    public var at: Date?
    /// What it wrote, as written.
    public var text: String
    /// The junction it spoke at; nil while it watched a run, or for a junction this app does not know.
    public var junction: ConductorJunction?
    /// Its own run, "Conductor run 2": the mechanical detail the row keeps under its help.
    public var runTitle: String?
    /// What it says about the run it watched; nil at a junction.
    public var watch: ConductorWatch?
    /// The blocks it carries, drawn after its words and before a closing `Next:` paragraph.
    public var blocks: [ConductorBlock]

    public init(
        id: String, at: Date?, text: String, junction: ConductorJunction? = nil, runTitle: String? = nil, watch: ConductorWatch? = nil,
        blocks: [ConductorBlock] = []
    ) {
        self.id = id
        self.at = at
        self.text = text
        self.junction = junction
        self.runTitle = runTitle
        self.watch = watch
        self.blocks = blocks
    }

    /// The message `event` records; nil for any other event or one with no text. `runTitle` names the Conductor's run.
    public init?(event: TicketEventsPayload.Event, runTitle: String? = nil) {
        guard event.type == Self.eventType, let text = event.payload.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
        else { return nil }
        self.init(
            id: event.id, at: event.date, text: text, junction: event.payload.junction.flatMap(ConductorJunction.init(rawValue:)),
            runTitle: runTitle, watch: event.payload.watch, blocks: event.payload.blocks
        )
    }

    public static let eventType = "conductor.update"
    /// The name it speaks under.
    public static let name = "Conductor"

    /// Its text read.
    public var markup: ConductorMarkup { ConductorMarkup(text) }

    /// The junction in words, after the name: "after coding".
    public var junctionWords: String? { junction?.words }

    /// It watched a run and sent it guidance or stopped it: drawn whole, inside the run.
    public var actedOnRun: Bool { watch?.acted ?? false }

    /// The message for VoiceOver, one element: "Conductor, after QA failed, 17:44, QA found one problem…". `time` is the
    /// clock as the row shows it.
    public func accessibilityLabel(time: String?) -> String {
        let parts: [String?] = [Self.name, junctionWords, watch?.action, watch?.timing, time, markup.plainText]
        return parts.compactMap { $0 }.joined(separator: ", ")
    }

    /// Where it is read in the ticket's history: a run's group holds it when it watched that run.
    public var watchedRunID: String? { watch?.runID }
}
