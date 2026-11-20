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
    public var at: String? { didSet { date = at.flatMap(TicketPage.date) } }
    /// `at` read once, when the line is made or its `at` changes.
    public private(set) var date: Date?
    /// How long the tool took, on a result.
    public var durationMs: Int?
    /// True on a result whose tool failed.
    public var failed: Bool

    enum CodingKeys: String, CodingKey { case kind, text, at, durationMs, failed }

    public init(kind: Kind, text: String, at: String? = nil, durationMs: Int? = nil, failed: Bool = false) {
        self.kind = kind
        self.text = text
        self.at = at
        self.date = at.flatMap(TicketPage.date)
        self.durationMs = durationMs
        self.failed = failed
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(Kind.self, forKey: .kind)
        text = try container.decode(String.self, forKey: .text)
        at = try? container.decodeIfPresent(String.self, forKey: .at)
        date = at.flatMap(TicketPage.date)
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
        public var startedAt: String? { didSet { startedDate = startedAt.flatMap(TicketPage.date) } }
        /// `startedAt` read once, when the step is made or its `startedAt` changes.
        public private(set) var startedDate: Date?

        enum CodingKeys: String, CodingKey { case id, title, startedAt }

        public init(id: String, title: String? = nil, startedAt: String? = nil) {
            self.id = id
            self.title = title
            self.startedAt = startedAt
            self.startedDate = startedAt.flatMap(TicketPage.date)
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                id: try container.decode(String.self, forKey: .id),
                title: try container.decodeIfPresent(String.self, forKey: .title),
                startedAt: try container.decodeIfPresent(String.self, forKey: .startedAt)
            )
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
        /// `blocked`: a QA check that could not judge (`StepAnswer.Result.judgement`).
        case done, current, failed, paused, skipped, blocked

        /// The row's word.
        public var word: String {
            switch self {
            case .done: "Done"
            case .current: "Working"
            case .failed: "Failed"
            case .paused: "Asked a question"
            case .skipped: "Skipped"
            case .blocked: "Blocked"
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
            case .blocked: .problem
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
            case .blocked: "exclamationmark.circle.fill"
            }
        }

        /// The glyph inside the step's round mark (the catalog's `.sl-mark`, which draws the circle itself).
        public var markSymbol: String {
            switch self {
            case .done: "checkmark"
            case .current: "circle.dotted"
            case .failed: "xmark"
            case .paused: "questionmark"
            case .skipped: "arrow.uturn.forward"
            case .blocked: "exclamationmark"
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
    /// The screenshots the run recorded while it was in this step.
    public var screenshots: [TicketScreenshot] = []

    public init(
        id: String, stepID: String, title: String, state: State, reason: String? = nil, durationSeconds: Int? = nil,
        transcript: TicketOutput? = nil, liveLines: [TranscriptLine] = [], screenshots: [TicketScreenshot] = [], answer: StepAnswer? = nil
    ) {
        self.id = id
        self.stepID = stepID
        self.title = title
        self.state = state
        self.reason = reason
        self.durationSeconds = durationSeconds
        self.transcript = transcript
        self.liveLines = liveLines
        self.screenshots = screenshots
        self.answer = answer
    }

    /// What the step answered, when Symphony recorded it on the step: shown above its lines.
    public var answer: StepAnswer?
    /// Why the step failed, whole, as Symphony recorded it; the row shows it in one line and the opened step in full.
    public var reasonDetail: String?

    /// The reason is longer than the row shows: more than a line's worth, or on several lines.
    public var hasLongReason: Bool { reasonDetail.map { $0.count > Self.rowReasonLimit || $0.contains("\n") } ?? false }
    static let rowReasonLimit = 80

    public var isLive: Bool { state == .current }

    /// A step the run stopped at: one that failed to run (not a QA check that judged the change failed), or asked.
    public var stopsTheRun: Bool {
        state == .paused || (state == .failed && answer?.result?.judgement != .failed)
    }

    /// Whether the step has lines to unfold into: a transcript, or the run now's lines. The step the run now is on
    /// unfolds before its first line comes, so that line fades in where the person sees it.
    public var canUnfold: Bool { isLive || transcript != nil || !liveLines.isEmpty || answer != nil || hasLongReason }

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

        /// The glyph inside the run's round mark (the catalog's `.run-head .mark`, which draws the circle itself).
        public var markSymbol: String {
            switch self {
            case .running: "circle.dotted"
            case .passed: "checkmark"
            case .failed: "exclamationmark"
            case .stopped: "stop.fill"
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
    /// The model as a person reads it, "Claude Opus 5.5"; nil when Symphony didn't say.
    public var model: String?
    /// The effort the run profile resolved, "high"; kept apart from the model's name.
    public var effort: String?
    /// How it came out, the meta line's last words: "Asked you a question"; nil while it runs.
    public var outcome: String?
    /// Why the run ended as it did, and what it answered, when Symphony put them on its `run.ended` and no step held them.
    public var endReason: String?
    public var endAnswer: StepAnswer?
    public var steps: [RunStep]
    /// One of its events is newer than the person's last look (TP-1451): an ended run's header carries the new dot.
    public var isNew = false
    /// The run now's newest lines while it is on no step: a run that walks no steps (a QA or Code Review run), or
    /// one between two steps. Drawn under the run.
    public var liveLines: [TranscriptLine] = []
    /// The run's whole session as lines, once it ended with a transcript: what the session reader reads for a run
    /// that walks no steps.
    public var transcript: TicketOutput?
    /// The screenshots the run recorded outside its steps, oldest first.
    public var screenshots: [TicketScreenshot] = []
    /// The Conductor's turn (run kind `conductor`): the timeline folds it behind "Show all events", where its update
    /// stands on its own.
    public var isMechanical = false
    /// The Conductor's guidance to the run while it ran (`conductor.steer`), oldest first.
    public var steers: [RunSteer] = []
    /// What the Conductor said while it watched the run (`conductor.update` with a `watch` of this run), oldest first,
    /// each with the step it comes after.
    public var conductorMessages: [RunConductorMessage] = []

    public init(
        id: String, title: String, state: State, word: String, durationSeconds: Int? = nil, tokens: Int? = nil,
        model: String? = nil, effort: String? = nil, outcome: String? = nil, steps: [RunStep] = []
    ) {
        self.id = id
        self.title = title
        self.state = state
        self.word = word
        self.durationSeconds = durationSeconds
        self.tokens = tokens
        self.model = model
        self.effort = effort
        self.outcome = outcome
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

    /// The line under the run's head (the prototype's `.run-meta`): "Claude Opus 5.5 · 12 min · 600K tokens · Asked
    /// you a question", the time so far while it runs. Nil when it has none of them.
    public var meta: String? {
        let reason = endReason.map { $0.split(whereSeparator: \.isNewline).joined(separator: " ") }
        let parts: [String] = [model, duration, tokensText, outcome, reason].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: Self.metaSeparator)
    }

    public static let metaSeparator = " · "

    /// The step the folded line names: the one it is on, else the one it stopped at (failed or asked), else its last.
    /// A QA check that judged the change failed did not stop the run, so it is not where it stopped.
    public var stoppedAt: RunStep? {
        steps.last { $0.state == .current } ?? steps.last(where: \.stopsTheRun) ?? steps.last
    }

    /// The folded line's "on Tests", "stopped at Checks", "ended after Handoff".
    public var whereText: String? {
        guard let step = stoppedAt else { return nil }
        if step.state == .current { return "on \(step.title)" }
        if step.stopsTheRun { return "stopped at \(step.title)" }
        return isLive ? "after \(step.title)" : "ended after \(step.title)"
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

    /// The run kind of the Conductor's turn.
    static let conductorKind = "conductor"

    /// Every run the history holds, oldest first; the running one with `runNow`'s current step and lines and
    /// `liveTokens`, and its duration so far against `reference`.
    public static func groups(
        _ history: TicketEventsPayload, runNow: RunNow? = nil, liveTokens: Int? = nil, reference: Date
    ) -> [RunGroupModel] {
        let byRun = Dictionary(grouping: history.events.filter { $0.runID != nil }, by: { $0.runID! })
        let watching = Dictionary(grouping: history.events.compactMap { event -> ConductorMessage? in
            let ownRun = event.runID.flatMap { history.runs[$0] }
            return ConductorMessage(event: event, runTitle: ownRun.map { TicketEventsPayload.runTitle(kind: $0.runKind, number: $0.runNumber) })
        }.filter { $0.watchedRunID != nil }, by: { $0.watchedRunID! })
        return history.runs.values
            .map { run in (run, byRun[run.runID] ?? []) }
            .sorted { lhs, rhs in
                let left = lhs.0.startedAt ?? lhs.1.first?.at ?? "", right = rhs.0.startedAt ?? rhs.1.first?.at ?? ""
                return left == right ? lhs.0.runID < rhs.0.runID : left < right
            }
            .map { run, events in
                let live = run.status?.lowercased() == "running"
                return group(
                    run, events: events, runNow: live ? runNow : nil, liveTokens: live ? liveTokens : nil, reference: reference,
                    conductorMessages: watching[run.runID] ?? []
                )
            }
    }

    /// The run `run` from its events, in the order Symphony wrote them.
    public static func group(
        _ run: TicketEventsPayload.Run, events: [TicketEventsPayload.Event], runNow: RunNow? = nil, liveTokens: Int? = nil,
        reference: Date, conductorMessages: [ConductorMessage] = []
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
        let startedAt = run.startedDate ?? started?.date
        let endedAt = run.endedDate ?? ended?.date
        let duration: Int? = if let ms = ended?.payload.durationMs {
            ms / 1_000
        } else if let startedAt, let end = endedAt ?? (state == .running ? reference : nil) {
            max(Int(end.timeIntervalSince(startedAt)), 0)
        } else {
            nil
        }
        let modelID = (run.model ?? started?.payload.model)?.trimmingWhitespace().nonEmpty
        let model = run.modelName?.trimmingWhitespace().nonEmpty ?? modelID.map(ModelName.display)
        let effort = (run.effort ?? started?.payload.effort)?.trimmingWhitespace().nonEmpty
        let live = state == .running
        var (steps, spans) = stepsAndSpans(events, live: live, runNow: runNow, reference: reference)
        let outside = placeScreenshots(events, in: &steps, spans: spans)
        var group = RunGroupModel(
            id: run.runID,
            title: TicketEventsPayload.runTitle(kind: run.runKind, number: run.runNumber),
            state: state,
            word: word.prefix(1).uppercased() + word.dropFirst(),
            durationSeconds: duration,
            tokens: ended?.payload.tokens ?? liveTokens,
            model: model,
            effort: effort,
            outcome: state == .running ? nil : run.outcome?.trimmingWhitespace().nonEmpty,
            steps: steps
        )
        // A run on no step (one that walks none, a QA or Code Review run, or one between steps) has its newest lines
        // under the run itself.
        if live, let runNow, runNow.currentStep == nil { group.liveLines = runNow.lines }
        group.endReason = ended?.payload.reason?.trimmingWhitespace().nonEmpty
        group.endAnswer = ended?.payload.answer.flatMap { $0.entries.isEmpty ? nil : $0 }
        group.transcript = ended?.artifacts.first { $0.kind == "transcript" }?.sessionLines
        group.screenshots = outside
        group.isMechanical = run.runKind == conductorKind
        // The steer's delivery stays a row of its own, unless the Conductor's message right beside it says the same words.
        let said = Set(conductorMessages.filter(\.actedOnRun).map(\.text))
        group.steers = events.compactMap(RunSteer.init(event:)).filter { !said.contains($0.text) }
        group.conductorMessages = conductorMessages.sorted { ($0.at ?? .distantFuture) < ($1.at ?? .distantFuture) }
            .map { RunConductorMessage(message: $0, afterStep: afterStep($0.at, steps: steps, spans: spans)) }
        return group
    }

    /// The step a message written at `at` comes after: the last that started before it. Nil puts it before the first step.
    /// A message with no time, or in a run whose steps carry no times, comes after the last.
    static func afterStep(_ at: Date?, steps: [RunStep], spans: [Int: StepSpan]) -> Int? {
        guard let at, !spans.isEmpty else { return steps.indices.last }
        return spans.filter { $0.value.start <= at }.keys.max()
    }

    /// The run's steps top to bottom: each `step.started` opens one, its `step.completed` ends it; a step completed
    /// without a start (skipped) is one of its own. A step a run that ended left open failed in it.
    static func steps(_ events: [TicketEventsPayload.Event], live: Bool, runNow: RunNow?, reference: Date) -> [RunStep] {
        stepsAndSpans(events, live: live, runNow: runNow, reference: reference).steps
    }

    /// When a step ran: from its start to its end, open while it has none (the step the run is on, or the one a run
    /// ended in).
    struct StepSpan: Equatable {
        var start: Date
        var end: Date?

        func contains(_ date: Date) -> Bool { date >= start && end.map { date <= $0 } ?? true }
    }

    /// The screenshots the run's events carry, each under the step whose span holds when it was recorded (the newest
    /// such step), else returned as the run's own. A finding's screenshots are its card's, never the run's.
    static func placeScreenshots(_ events: [TicketEventsPayload.Event], in steps: inout [RunStep], spans: [Int: StepSpan]) -> [TicketScreenshot] {
        var outside: [TicketScreenshot] = []
        var seen = Set<String>()
        for event in events where event.type != "finding.recorded" {
            let shots = event.screenshots.filter { seen.insert($0.id).inserted }
            guard !shots.isEmpty else { continue }
            let index = event.date.flatMap { date in steps.indices.last { spans[$0]?.contains(date) == true } }
            if let index { steps[index].screenshots += shots } else { outside += shots }
        }
        return outside
    }

    static func stepsAndSpans(
        _ events: [TicketEventsPayload.Event], live: Bool, runNow: RunNow?, reference: Date
    ) -> (steps: [RunStep], spans: [Int: StepSpan]) {
        var steps: [RunStep] = []
        var startedAt: [Int: Date] = [:]
        var endedAt: [Int: Date] = [:]
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
            let at = event.date
            if event.type == "step.started" {
                _ = begin(stepID, title: event.payload.title, at: at)
                continue
            }
            let index = steps.lastIndex { $0.stepID == stepID && $0.state == .current } ?? begin(stepID, title: event.payload.title, at: nil)
            var step = steps[index]
            if let title = event.payload.title?.trimmingWhitespace().nonEmpty { step.title = title }
            (step.state, step.reason) = completion(event.payload)
            step.answer = event.payload.answer
            if step.state == .failed { step.reasonDetail = event.payload.reason?.trimmingWhitespace().nonEmpty }
            if let ms = event.payload.durationMs {
                step.durationSeconds = ms / 1_000
            } else if let begun = startedAt[index], let at {
                step.durationSeconds = max(Int(at.timeIntervalSince(begun)), 0)
            }
            step.transcript = event.artifacts.first { $0.kind == "transcript" }.map(\.output)
            steps[index] = step
            if let at { endedAt[index] = at }
        }

        // The run now's step, written to the read before the feed has its start.
        if live, let current = runNow?.currentStep, !steps.contains(where: { $0.stepID == current.id && $0.state == .current }) {
            _ = begin(current.id, title: current.title, at: current.startedDate)
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
        let spans = Dictionary(uniqueKeysWithValues: startedAt.map { index, start in (index, StepSpan(start: start, end: endedAt[index])) })
        return (steps, spans)
    }

    static let endedInStep = "The run ended during this step"

    /// A `step.completed`'s state and its reason. A step that ran to an answer and judged it (a QA check's
    /// `result.status`) is drawn with what it judged; "the step ran" is not what the row says.
    static func completion(_ payload: TicketEventsPayload.Payload) -> (RunStep.State, String?) {
        switch payload.outcome?.lowercased() {
        case "passed":
            return (payload.answer?.result?.judgement ?? .done, payload.reason?.trimmingWhitespace().nonEmpty)
        case "failed":
            let back = payload.returnsToTitle?.trimmingWhitespace().nonEmpty ?? payload.returnsTo?.trimmingWhitespace().nonEmpty
            return (.failed, back.map { "back to \($0)" } ?? payload.reason?.trimmingWhitespace().nonEmpty)
        case "paused": return (.paused, "waiting on your answer")
        case "skipped": return (.skipped, payload.reason?.trimmingWhitespace().nonEmpty)
        default: return (.done, payload.reason?.trimmingWhitespace().nonEmpty)
        }
    }
}

/// A model's name as a person reads it, for a Symphony whose feed doesn't name it (`model_name`): its id read as
/// Symphony reads it, so `claude-opus-5-5` is "Claude Opus 5.5" and `claude-haiku-4-5-20251001` "Claude Haiku 4.5".
public enum ModelName {
    static let upper: [String: String] = ["gpt": "GPT", "glm": "GLM", "ai": "AI"]

    public static func display(_ id: String) -> String {
        let name: String = id.split(separator: "/").last.map(String.init) ?? id
        var parts: [String] = name.split(separator: "-").map { String($0) }
        if let last = parts.last, last.count == 8, last.allSatisfy(\.isNumber) { parts.removeLast() }
        var words: [String] = []
        var version: [String] = []
        // Numbers next to each other are one version ("5", "5" is "5.5"); any other part is a word.
        for part in parts {
            if part.allSatisfy(\.isNumber) {
                version.append(part)
                continue
            }
            if !version.isEmpty { words.append(version.joined(separator: ".")); version = [] }
            words.append(upper[part] ?? (part.prefix(1).uppercased() + part.dropFirst()))
        }
        if !version.isEmpty { words.append(version.joined(separator: ".")) }
        return words.joined(separator: " ")
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

/// The Conductor's guidance to a running run (`conductor.steer`): one entry inside the run's group, at its time,
/// "Conductor steered" with the message.
public struct RunSteer: Equatable, Identifiable {
    public var id: String
    public var at: Date?
    public var text: String

    /// The entry's title.
    public static let title = "Conductor steered"

    public init(id: String, at: Date?, text: String) {
        self.id = id
        self.at = at
        self.text = text
    }

    /// The steer `event` records; nil for any other event, or one with no text.
    public init?(event: TicketEventsPayload.Event) {
        guard event.type == "conductor.steer", let text = event.payload.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        self.init(id: event.id, at: event.date, text: text)
    }
}

/// A message of the Conductor inside a run's group, with the step it comes after.
public struct RunConductorMessage: Equatable, Identifiable {
    public var message: ConductorMessage
    /// The index of the step it follows; nil puts it above the first step.
    public var afterStep: Int?

    public var id: String { message.id }

    public init(message: ConductorMessage, afterStep: Int?) {
        self.message = message
        self.afterStep = afterStep
    }
}
