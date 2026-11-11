import Foundation

// A run as the Run group and the Step list draw it (`docs/design/director-ticket-page.md` §1 facts 4, 8 and 13, §4):
// one run of an agent folded into its steps, each step into what the agent said, each tool it called and what came
// back. Built from the ticket's events feed (`run.started`, `run.ended`, `step.started`, `step.completed` with the
// `transcript` artifact each completed step carries) and, for the run now, the ticket read's `running.current_step`
// and `running.recent_lines`.

/// One line of a step's transcript: what the agent said (`say`), a tool it called with its arguments in short
/// (`tool`), or what the tool returned (`result`), with how long it took and whether it failed.
public struct TranscriptLine: Equatable, Hashable, Decodable {
    public enum Kind: String, Decodable, Equatable, Hashable {
        case say, tool, result
    }

    public var kind: Kind
    public var text: String
    /// When it happened, as Symphony wrote it; nil when the source gave no time.
    public var at: String?
    /// How long the tool took, on a result.
    public var durationMs: Int?
    /// True on a result whose tool failed.
    public var failed: Bool

    enum CodingKeys: String, CodingKey { case kind, text, at, durationMs, failed }

    public init(kind: Kind, text: String, at: String? = nil, durationMs: Int? = nil, failed: Bool = false) {
        self.kind = kind
        self.text = text
        self.at = at
        self.durationMs = durationMs
        self.failed = failed
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(Kind.self, forKey: .kind)
        text = try container.decode(String.self, forKey: .text)
        at = try? container.decodeIfPresent(String.self, forKey: .at)
        durationMs = try? container.decodeIfPresent(Int.self, forKey: .durationMs)
        failed = (try? container.decodeIfPresent(Bool.self, forKey: .failed)) == true
    }

    /// The lines of a `transcript` artifact: one JSON object a line. A line that isn't one, or of a kind the app
    /// doesn't know, is skipped.
    public static func lines(_ data: Data) -> [TranscriptLine] {
        String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .compactMap { try? decoder.decode(TranscriptLine.self, from: Data($0.utf8)) }
    }

    public var date: Date? { at.flatMap(TicketPage.date) }

    /// A tool call's tool: "Bash" of "Bash: mix test". Nil on another kind, or a call with no name before a colon.
    public var toolName: String? {
        guard kind == .tool, let colon = text.range(of: ": ") else { return nil }
        let name = text[..<colon.lowerBound]
        return name.isEmpty || name.contains(" ") ? nil : String(name)
    }

    /// A tool call's arguments in short, "mix test" of "Bash: mix test"; any other line's text.
    public var body: String {
        guard let name = toolName else { return text }
        return String(text.dropFirst(name.count + 2))
    }

    /// "840 ms", "1.2 s", "2 min 4 s": how long a result's tool took.
    public var durationText: String? { durationMs.map(Self.duration) }

    static func duration(_ ms: Int) -> String {
        let ms = max(ms, 0)
        switch ms {
        case ..<1_000: return "\(ms) ms"
        case ..<10_000: return String(format: "%.1f s", Double(ms) / 1_000)
        case ..<60_000: return "\(ms / 1_000) s"
        default:
            let seconds = ms / 1_000
            return seconds % 60 == 0 ? "\(seconds / 60) min" : "\(seconds / 60) min \(seconds % 60) s"
        }
    }

    /// VoiceOver's word for the line: "The agent said: …", "Tool call Bash: mix test", "Result, failed, 1.2 s: …".
    public var accessibilityLabel: String {
        switch kind {
        case .say: return "The agent said: \(text)"
        case .tool: return "Tool call \(text)"
        case .result:
            let lead = (["Result"] + (failed ? ["failed"] : []) + [durationText].compactMap { $0 }).joined(separator: ", ")
            return "\(lead): \(text)"
        }
    }

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()
}

/// What the ticket read says of the run now: the step it is on (nil between steps) and that step's newest lines.
public struct RunNow: Equatable {
    public struct CurrentStep: Equatable, Decodable {
        public var id: String
        public var title: String?
        public var startedAt: String?

        public init(id: String, title: String? = nil, startedAt: String? = nil) {
            self.id = id
            self.title = title
            self.startedAt = startedAt
        }
    }

    public var currentStep: CurrentStep?
    public var lines: [TranscriptLine]

    public init(currentStep: CurrentStep?, lines: [TranscriptLine]) {
        self.currentStep = currentStep
        self.lines = lines
    }

    /// The ticket read's `running`, nil when no run is working on the ticket or the read doesn't say.
    public static func decode(issue data: Data) -> RunNow? {
        struct Running: Decodable {
            let currentStep: CurrentStep?
            let recentLines: [Lossy]?
        }
        struct Issue: Decodable {
            let running: Running?
        }
        guard let running = (try? TranscriptLine.decoder.decode(Issue.self, from: data))?.running else { return nil }
        return RunNow(currentStep: running.currentStep, lines: (running.recentLines ?? []).compactMap(\.line))
    }

    /// A line, or nothing when it doesn't decode, so one odd line doesn't lose the others.
    private struct Lossy: Decodable {
        let line: TranscriptLine?
        init(from decoder: Decoder) throws { line = try? TranscriptLine(from: decoder) }
    }
}

/// One step of a run, as the Step list's row shows it.
public struct RunStep: Equatable, Identifiable {
    public enum State: String, Equatable {
        case done, current, failed, paused, skipped

        /// The row's word.
        public var word: String {
            switch self {
            case .done: "Done"
            case .current: "Working"
            case .failed: "Failed"
            case .paused: "Asked a question"
            case .skipped: "Skipped"
            }
        }

        /// The status its mark and tint take.
        public var status: DesignTokens.Status {
            switch self {
            case .done: .done
            case .current: .working
            case .failed: .problem
            case .paused: .you
            case .skipped: .idle
            }
        }

        /// The mark's symbol; the current step draws a live dot instead.
        public var symbol: String {
            switch self {
            case .done: "checkmark.circle.fill"
            case .current: "circle.dotted.circle"
            case .failed: "xmark.circle.fill"
            case .paused: "questionmark.circle.fill"
            case .skipped: "arrow.uturn.forward.circle"
            }
        }
    }

    /// Unique in its run: the step's id, numbered from its second time in the run ("code#2").
    public var id: String
    /// The step's id in the step list: "code", "tests".
    public var stepID: String
    /// "Write the code", "Tests".
    public var title: String
    public var state: State
    /// Why it was skipped, where a failed one sends the run, what a paused one waits on.
    public var reason: String?
    public var durationSeconds: Int?
    /// The step's transcript artifact, once it completed with one.
    public var transcript: TicketOutput?
    /// The newest lines of the run now's current step.
    public var liveLines: [TranscriptLine] = []

    public init(
        id: String, stepID: String, title: String, state: State, reason: String? = nil, durationSeconds: Int? = nil,
        transcript: TicketOutput? = nil, liveLines: [TranscriptLine] = []
    ) {
        self.id = id
        self.stepID = stepID
        self.title = title
        self.state = state
        self.reason = reason
        self.durationSeconds = durationSeconds
        self.transcript = transcript
        self.liveLines = liveLines
    }

    public var isLive: Bool { state == .current }

    /// Whether the step has lines to unfold into: a transcript, or the run now's lines. The step the run now is on
    /// unfolds before its first line comes, so that line fades in where the person sees it.
    public var canUnfold: Bool { isLive || transcript != nil || !liveLines.isEmpty }

    /// What the pointer shows on a step that can't unfold.
    public var cannotUnfoldReason: String? { canUnfold ? nil : Self.nothingYet }
    public static let nothingYet = "Nothing happened in this step yet"

    /// Unfolded by default: the step it is on, and one that failed or asked a question.
    public var opensByDefault: Bool { canUnfold && [.current, .failed, .paused].contains(state) }

    public var duration: String? { durationSeconds.map(Overview.duration) }

    /// The step's row for VoiceOver: "Tests, failed, 2 minutes, back to Write the code".
    public var accessibilityLabel: String {
        ([title, state.word.lowercased(), durationSeconds.map(Overview.spokenDuration), reason].compactMap { $0 }).joined(separator: ", ")
    }

    /// The fold's button: "Expand Tests, failed", "Collapse Tests, failed".
    public func foldAccessibilityLabel(folded: Bool) -> String {
        (folded ? "Expand " : "Collapse ") + title + ", " + state.word.lowercased()
    }
}

/// One run of an agent, as the Run group shows it: its header and its steps.
/// What a person folded or unfolded by hand, over what opens by default. Only their own folds are kept, so a step
/// that comes to open by default (a step just started, the run now's step gaining its first line, one that just
/// failed) opens as the ticket read brings it, and a fold the person made stays as they left it.
public struct FoldState: Equatable {
    public private(set) var overrides: [String: Bool]

    public init(overrides: [String: Bool] = [:]) {
        self.overrides = overrides
    }

    /// Every one of `ids` pinned open when `unfolded` names it, folded otherwise.
    public init(ids: [String], unfolded: Set<String>) {
        self.init(overrides: Dictionary(ids.map { ($0, unfolded.contains($0)) }, uniquingKeysWith: { first, _ in first }))
    }

    public func isUnfolded(_ id: String, byDefault: Bool) -> Bool { overrides[id] ?? byDefault }

    public mutating func toggle(_ id: String, byDefault: Bool) {
        overrides[id] = !isUnfolded(id, byDefault: byDefault)
    }

    /// A step is open when it can unfold and the person opened it, or left it and it opens by default.
    public func isUnfolded(_ step: RunStep) -> Bool {
        step.canUnfold && isUnfolded(step.id, byDefault: step.opensByDefault)
    }

    public mutating func toggle(_ step: RunStep) {
        overrides[step.id] = !isUnfolded(step)
    }
}

public struct RunGroupModel: Equatable, Identifiable {
    public enum State: String, Equatable {
        case running, passed, failed, stopped

        public var status: DesignTokens.Status {
            switch self {
            case .running: .working
            case .passed: .done
            case .failed: .problem
            case .stopped: .idle
            }
        }

        /// The header mark's symbol; the running one draws a live dot instead.
        public var symbol: String {
            switch self {
            case .running: "circle.dotted.circle"
            case .passed: "checkmark.circle.fill"
            case .failed: "exclamationmark.triangle.fill"
            case .stopped: "stop.circle"
            }
        }
    }

    /// The run's id.
    public var id: String
    /// "Implementation run 2".
    public var title: String
    public var state: State
    /// "Running", "Passed", "Sent back", "Handoff".
    public var word: String
    public var durationSeconds: Int?
    public var tokens: Int?
    /// "claude-opus-5-5 · high", nil when Symphony didn't say.
    public var model: String?
    public var steps: [RunStep]
    /// One of its events is newer than the person's last look (TP-1451): an ended run's header carries the new dot.
    public var isNew = false

    public init(
        id: String, title: String, state: State, word: String, durationSeconds: Int? = nil, tokens: Int? = nil,
        model: String? = nil, steps: [RunStep] = []
    ) {
        self.id = id
        self.title = title
        self.state = state
        self.word = word
        self.durationSeconds = durationSeconds
        self.tokens = tokens
        self.model = model
        self.steps = steps
    }

    public var isLive: Bool { state == .running }

    /// The new dot on its header: an ended run with something new; the run now says it is live instead.
    public var showsNewDot: Bool { isNew && !isLive }

    /// Unfolded by default while it runs; folded once it ended.
    public var opensByDefault: Bool { isLive }

    /// "42 min so far" while it runs, "22 min" once it ended.
    public var duration: String? {
        durationSeconds.map { Overview.duration($0) + (isLive ? " so far" : "") }
    }

    public var tokensText: String? { tokens.flatMap { $0 > 0 ? Overview.tokens($0) + " tokens" : nil } }

    /// The step the folded line names: the one it is on, else the one it stopped at (failed or asked), else its last.
    public var stoppedAt: RunStep? {
        steps.last { $0.state == .current } ?? steps.last { [.failed, .paused].contains($0.state) } ?? steps.last
    }

    /// The folded line's "on Tests", "stopped at Checks", "ended after Handoff".
    public var whereText: String? {
        guard let step = stoppedAt else { return nil }
        switch step.state {
        case .current: return "on \(step.title)"
        case .failed, .paused: return "stopped at \(step.title)"
        case .done, .skipped: return isLive ? "after \(step.title)" : "ended after \(step.title)"
        }
    }

    /// The header for VoiceOver: "Implementation run 2, running, on Tests, 42 minutes, 1.2M tokens".
    public var accessibilityLabel: String {
        let spoken = durationSeconds.map(Overview.spokenDuration)
        let new = showsNewDot ? TimelineEntry.newWords : nil
        return ([title, word.lowercased(), whereText, spoken, tokensText, model, new].compactMap { $0 }).joined(separator: ", ")
    }

    /// The fold's button: "Expand Implementation run 1, failed".
    public func foldAccessibilityLabel(folded: Bool) -> String {
        (folded ? "Expand " : "Collapse ") + title + ", " + word.lowercased()
    }

    // MARK: - Building

    /// Every run the history holds, oldest first; the running one with `runNow`'s current step and lines and
    /// `liveTokens`, and its duration so far against `reference`.
    public static func groups(
        _ history: TicketEventsPayload, runNow: RunNow? = nil, liveTokens: Int? = nil, reference: Date
    ) -> [RunGroupModel] {
        let byRun = Dictionary(grouping: history.events.filter { $0.runID != nil }, by: { $0.runID! })
        return history.runs.values
            .map { run in (run, byRun[run.runID] ?? []) }
            .sorted { lhs, rhs in
                let left = lhs.0.startedAt ?? lhs.1.first?.at ?? "", right = rhs.0.startedAt ?? rhs.1.first?.at ?? ""
                return left == right ? lhs.0.runID < rhs.0.runID : left < right
            }
            .map { run, events in
                let live = run.status?.lowercased() == "running"
                return group(run, events: events, runNow: live ? runNow : nil, liveTokens: live ? liveTokens : nil, reference: reference)
            }
    }

    /// The run `run` from its events, in the order Symphony wrote them.
    public static func group(
        _ run: TicketEventsPayload.Run, events: [TicketEventsPayload.Event], runNow: RunNow? = nil, liveTokens: Int? = nil,
        reference: Date
    ) -> RunGroupModel {
        let (result, word) = TicketEventsPayload.runState(run)
        let state: State = switch result {
        case .current: .running
        case .done: .passed
        case .failed: .failed
        case .stopped: .stopped
        }
        let started = events.first { $0.type == "run.started" }
        let ended = events.last { $0.type == "run.ended" }
        let startedAt = run.startedAt.flatMap(TicketPage.date) ?? started?.at.flatMap(TicketPage.date)
        let endedAt = run.endedAt.flatMap(TicketPage.date) ?? ended?.at.flatMap(TicketPage.date)
        let duration: Int? = if let ms = ended?.payload.durationMs {
            ms / 1_000
        } else if let startedAt, let end = endedAt ?? (state == .running ? reference : nil) {
            max(Int(end.timeIntervalSince(startedAt)), 0)
        } else {
            nil
        }
        let model = [run.model ?? started?.payload.model, run.effort ?? started?.payload.effort]
            .compactMap { $0?.trimmingWhitespace() }
            .filter { !$0.isEmpty }
        return RunGroupModel(
            id: run.runID,
            title: TicketEventsPayload.runTitle(kind: run.runKind, number: run.runNumber),
            state: state,
            word: word.prefix(1).uppercased() + word.dropFirst(),
            durationSeconds: duration,
            tokens: ended?.payload.tokens ?? liveTokens,
            model: model.isEmpty ? nil : model.joined(separator: " · "),
            steps: steps(events, live: state == .running, runNow: runNow, reference: reference)
        )
    }

    /// The run's steps top to bottom: each `step.started` opens one, its `step.completed` ends it; a step completed
    /// without a start (skipped) is one of its own. A step a run that ended left open failed in it.
    static func steps(_ events: [TicketEventsPayload.Event], live: Bool, runNow: RunNow?, reference: Date) -> [RunStep] {
        var steps: [RunStep] = []
        var startedAt: [Int: Date] = [:]
        var times: [String: Int] = [:]

        func begin(_ stepID: String, title: String?, at: Date?) -> Int {
            times[stepID, default: 0] += 1
            let count = times[stepID]!
            steps.append(RunStep(
                id: count == 1 ? stepID : "\(stepID)#\(count)", stepID: stepID, title: title?.trimmingWhitespace().nonEmpty ?? stepID,
                state: .current
            ))
            if let at { startedAt[steps.count - 1] = at }
            return steps.count - 1
        }

        for event in events where event.type == "step.started" || event.type == "step.completed" {
            guard let stepID = event.payload.stepID?.trimmingWhitespace().nonEmpty else { continue }
            let at = event.at.flatMap(TicketPage.date)
            if event.type == "step.started" {
                _ = begin(stepID, title: event.payload.title, at: at)
                continue
            }
            let index = steps.lastIndex { $0.stepID == stepID && $0.state == .current } ?? begin(stepID, title: event.payload.title, at: nil)
            var step = steps[index]
            if let title = event.payload.title?.trimmingWhitespace().nonEmpty { step.title = title }
            (step.state, step.reason) = completion(event.payload)
            if let ms = event.payload.durationMs {
                step.durationSeconds = ms / 1_000
            } else if let begun = startedAt[index], let at {
                step.durationSeconds = max(Int(at.timeIntervalSince(begun)), 0)
            }
            step.transcript = event.artifacts.first { $0.kind == "transcript" }.map(\.output)
            steps[index] = step
        }

        // The run now's step, written to the read before the feed has its start.
        if live, let current = runNow?.currentStep, !steps.contains(where: { $0.stepID == current.id && $0.state == .current }) {
            _ = begin(current.id, title: current.title, at: current.startedAt.flatMap(TicketPage.date))
        }

        for index in steps.indices where steps[index].state == .current {
            if live {
                if let begun = startedAt[index] { steps[index].durationSeconds = max(Int(reference.timeIntervalSince(begun)), 0) }
                if let runNow, runNow.currentStep?.id == steps[index].stepID { steps[index].liveLines = runNow.lines }
            } else {
                steps[index].state = .failed
                steps[index].reason = endedInStep
            }
        }
        return steps
    }

    static let endedInStep = "The run ended during this step"

    /// A `step.completed`'s state and its reason.
    static func completion(_ payload: TicketEventsPayload.Payload) -> (RunStep.State, String?) {
        switch payload.outcome?.lowercased() {
        case "failed":
            let back = payload.returnsToTitle?.trimmingWhitespace().nonEmpty ?? payload.returnsTo?.trimmingWhitespace().nonEmpty
            return (.failed, back.map { "back to \($0)" })
        case "paused": return (.paused, "waiting on your answer")
        case "skipped": return (.skipped, payload.reason?.trimmingWhitespace().nonEmpty)
        default: return (.done, nil)
        }
    }
}

/// The transcripts of the steps a person unfolded, read through the window's API client on a step's first unfold
/// and kept by artifact id: an id is the hash of its bytes, so what it names never changes.
@MainActor
public final class StepTranscripts: ObservableObject {
    public enum Lines: Equatable {
        case loading
        case loaded([TranscriptLine])
        /// Symphony no longer keeps it (`available: false`, a 404 or a 410).
        case unavailable
        /// It couldn't be read just now; unfolding the step again reads it again.
        case failed
    }

    public typealias Get = (_ path: String) async -> APIAnswer

    /// How many transcripts it keeps; past that the oldest goes.
    public static let capacity = 32

    @Published public private(set) var transcripts: [String: Lines] = [:]
    /// Every path it asked for, oldest first.
    public private(set) var requests: [String] = []
    private var loadedOrder: [String] = []
    private let get: Get

    public init(get: @escaping Get) {
        self.get = get
    }

    /// What the unfolded step shows now.
    public func lines(_ transcript: TicketOutput) -> Lines {
        guard transcript.available else { return .unavailable }
        return transcripts[transcript.id] ?? .loading
    }

    /// Reads `transcript` unless it is kept, being read, or unavailable.
    @discardableResult
    public func load(_ transcript: TicketOutput) -> Task<Void, Never>? {
        guard transcript.available else { return nil }
        switch transcripts[transcript.id] {
        case .loading?, .loaded?, .unavailable?: return nil
        case .failed?, nil: break
        }
        transcripts[transcript.id] = .loading
        requests.append(transcript.path)
        return Task {
            let answer = await get(transcript.path)
            store(Self.lines(answer), for: transcript.id)
        }
    }

    /// Keeps `lines` as `id`'s, as a read would: the snapshots draw a step's lines without a server.
    public func keep(_ lines: [TranscriptLine], for id: String) {
        store(.loaded(lines), for: id)
    }

    /// What an answer to an artifact's GET shows.
    nonisolated static func lines(_ answer: APIAnswer) -> Lines {
        switch answer {
        case let .answered(data, 200): return .loaded(TranscriptLine.lines(data))
        case .answered(_, 404), .answered(_, 410): return .unavailable
        case .answered, .unreachable: return .failed
        }
    }

    private func store(_ lines: Lines, for id: String) {
        transcripts[id] = lines
        guard case .loaded = lines else { return }
        loadedOrder.removeAll { $0 == id }
        loadedOrder.append(id)
        while loadedOrder.count > Self.capacity {
            transcripts[loadedOrder.removeFirst()] = nil
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
