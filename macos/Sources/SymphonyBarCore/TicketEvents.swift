import Combine
import Foundation
import ImageIO

/// A screenshot an event of the ticket's history carries, as its row shows it.
public struct TicketScreenshot: Equatable, Hashable, Identifiable {
    /// The artifact's id: the hash of its bytes, so the bytes behind it never change.
    public var id: String
    public var label: String
    /// Its bytes' path on Symphony's API, such as `api/v1/artifacts/<id>`.
    public var path: String
    /// False once Symphony no longer keeps the file.
    public var available: Bool

    public init(id: String, label: String, path: String, available: Bool) {
        self.id = id
        self.label = label
        self.path = path
        self.available = available
    }

    /// VoiceOver's word for the thumbnail: "Screenshot Run header at 1440×900, opens full size".
    public var accessibilityLabel: String { "Screenshot \(label), opens full size" }
    /// VoiceOver's word for the placeholder that stands in for it.
    public var unavailableAccessibilityLabel: String { "Screenshot \(label) unavailable" }
    public static let unavailableTitle = "Screenshot unavailable"
}

/// The ticket's history as Symphony's events feed serves it grouped by run
/// (`GET /api/v1/repos/:repo_key/tickets/:issue_identifier/events?group=run`): the events a run holds sit in it, a
/// reply under the event it answers. Pages merge into one history by run id and event id, and the history maps to the
/// timeline's steps.
public struct TicketEventsPayload: Equatable {
    public struct Actor: Decodable, Equatable {
        public var kind: String?
        public var name: String?
    }

    public struct Summary: Decodable, Equatable {
        public var title: String?
        public var detail: String?
    }

    /// A file an event carries.
    public struct Artifact: Decodable, Equatable {
        public var id: String
        public var kind: String?
        public var label: String?
        public var mime: String?
        public var url: String?
        public var available: Bool?

        var isImage: Bool { kind == "screenshot" || mime?.hasPrefix("image/") == true }

        var screenshot: TicketScreenshot {
            let path = url.map { $0.hasPrefix("/") ? String($0.dropFirst()) : $0 }.flatMap { $0.isEmpty ? nil : $0 }
            return TicketScreenshot(
                id: id, label: label?.trimmingWhitespace().trimmedNonEmpty ?? "without a label",
                path: path ?? "api/v1/artifacts/\(id)", available: available ?? true
            )
        }
    }

    /// The fields of an event's payload the timeline reads; any other field, or a field of another type, is ignored.
    public struct Payload: Decodable, Equatable {
        public var kind: String?
        public var outcome: String?
        public var exit: String?

        enum CodingKeys: String, CodingKey { case kind, outcome, exit }

        public init(kind: String? = nil, outcome: String? = nil, exit: String? = nil) {
            self.kind = kind
            self.outcome = outcome
            self.exit = exit
        }

        public init(from decoder: Decoder) throws {
            let container = try? decoder.container(keyedBy: CodingKeys.self)
            func text(_ key: CodingKeys) -> String? { (try? container?.decodeIfPresent(String.self, forKey: key)) ?? nil }
            self.init(kind: text(.kind), outcome: text(.outcome), exit: text(.exit))
        }
    }

    public struct Event: Equatable {
        public var id: String
        public var seq: Int?
        public var at: String?
        public var type: String
        public var runID: String?
        public var parent: String?
        public var actor: Actor?
        public var summary: Summary?
        public var payload: Payload
        public var artifacts: [Artifact]
    }

    /// A run's verdict, when one names it.
    public struct Verdict: Decodable, Equatable {
        public var kind: String?
        public var outcome: String?
        public var head: String?
        public var at: String?
    }

    /// A run's header, read from the ticket's whole history: a newer page's replaces an older one's.
    public struct Run: Equatable {
        public var runID: String
        public var runKind: String?
        public var runNumber: Int?
        /// `running` until the run ends, then `ended`.
        public var status: String?
        public var exit: String?
        public var verdict: Verdict?
        public var startedAt: String?
        public var endedAt: String?
        public var head: String?
    }

    /// The headers of the runs the history holds, by run id.
    public private(set) var runs: [String: Run] = [:]
    /// Every event once, in the order Symphony wrote them.
    public private(set) var events: [Event] = []
    /// The newest page's `next_since`: what the next read passes as `since`.
    public private(set) var nextSince: String?

    public init() {}

    public var isEmpty: Bool { events.isEmpty && runs.isEmpty }

    /// A feed page, nil when it isn't one.
    public static func decode(_ data: Data) -> TicketEventsPayload? {
        guard let page = try? decoder.decode(Page.self, from: data) else { return nil }
        var payload = TicketEventsPayload()
        payload.nextSince = page.nextSince
        for entry in page.timeline {
            switch entry {
            case let .run(run, members):
                payload.runs[run.runID] = run
                payload.events += members.flatMap(\.flattened)
            case let .event(node):
                payload.events += node.flattened
            }
        }
        payload.events = Self.ordered(Self.unique(payload.events))
        return payload
    }

    /// Takes in `newer`, a later page: its run headers replace the ones held, an event already held is replaced by its
    /// newer copy, and the rest are added. Returns how many events were new.
    @discardableResult
    public mutating func merge(_ newer: TicketEventsPayload) -> Int {
        runs.merge(newer.runs) { _, new in new }
        var index = Dictionary(events.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        var added = 0
        for event in newer.events {
            if let at = index[event.id] {
                events[at] = event
            } else {
                index[event.id] = events.count
                events.append(event)
                added += 1
            }
        }
        if added > 0 { events = Self.ordered(events) }
        nextSince = newer.nextSince ?? nextSince
        return added
    }

    /// When the newest event the history holds happened.
    public var newestEventAt: Date? { events.compactMap { $0.at.flatMap(TicketPage.date) }.max() }

    // MARK: - The timeline

    /// The history as the timeline's steps, oldest first: each run a group holding its events (its verdict last, its
    /// start and end in its header), each reply under the event it answers, and the events of no run between them.
    public func steps(reference: Date, clock: (Date) -> String) -> [TicketPage.Step] {
        // Placed as Symphony places them: under a parent written earlier, else in their run, else at the top.
        enum Place: Hashable { case top, run(String), event(String) }
        var seen = Set<String>()
        var members: [Place: [Event]] = [:]
        var top: [(run: String?, event: Event?)] = []
        var runsPlaced = Set<String>()
        for event in events {
            let place: Place
            if let parent = event.parent, seen.contains(parent) {
                place = .event(parent)
            } else if let runID = event.runID, runs[runID] != nil {
                place = .run(runID)
            } else {
                place = .top
            }
            seen.insert(event.id)
            switch place {
            case .top:
                top.append((nil, event))
            case let .run(runID):
                if runsPlaced.insert(runID).inserted { top.append((runID, nil)) }
                members[place, default: []].append(event)
            case .event:
                members[place, default: []].append(event)
            }
        }
        // A run with no event on the pages read still shows, by its start.
        for runID in runs.keys.sorted() where !runsPlaced.contains(runID) {
            top.append((runID, nil))
        }

        func step(_ event: Event) -> TicketPage.Step {
            Self.eventStep(event, children: (members[.event(event.id)] ?? []).map(step), clock: clock)
        }

        var steps: [TicketPage.Step] = []
        for entry in top {
            if let event = entry.event {
                steps.append(step(event))
            } else if let runID = entry.run, let run = runs[runID] {
                let inside = (members[.run(runID)] ?? []).filter { !Self.headerTypes.contains($0.type) }
                // The verdict closes its run: the last row, whenever it was written.
                let ordered = inside.filter { $0.type != "verdict.recorded" } + inside.filter { $0.type == "verdict.recorded" }
                let started = run.startedAt.flatMap(TicketPage.date)
                    ?? (members[.run(runID)] ?? []).lazy.compactMap { $0.at.flatMap(TicketPage.date) }.first
                guard let started else { continue }
                steps.append(Self.runStep(run, started: started, children: ordered.map(step), reference: reference, clock: clock))
            }
        }
        return steps
    }

    /// The events a run's header stands for.
    static let headerTypes: Set<String> = ["run.started", "run.ended"]

    /// "QA run 2", "Implementation run 1", "Code Review run 3".
    public static func runTitle(kind: String?, number: Int?) -> String {
        let name: String
        switch kind {
        case nil, "": name = "Agent"
        case "qa": name = "QA"
        case "code_review": name = "Code Review"
        case "ci_fix": name = "CI Fix"
        case let kind?: name = Overview.phaseName(kind)
        }
        return number.map { "\(name) run \($0)" } ?? "\(name) run"
    }

    /// A run's state: its verdict's outcome when it has one, else running, else how it ended.
    static func runState(_ run: Run) -> (TicketPage.Step.Result, String) {
        if let verdict = run.verdict, let outcome = verdict.outcome?.trimmedNonEmpty {
            return verdictState(kind: verdict.kind, outcome: outcome)
        }
        if run.status?.lowercased() == "running" { return (.current, "running") }
        return exitState(run.exit)
    }

    /// "passed", "failed", "approved", "sent back".
    static func verdictState(kind: String?, outcome: String) -> (TicketPage.Step.Result, String) {
        switch (kind, outcome) {
        case ("qa", "pass"): return (.done, "passed")
        case ("qa", "fail"): return (.failed, "failed")
        case ("qa", "skip"): return (.done, "skipped")
        case ("code_review", "approve"): return (.done, "approved")
        case ("code_review", "rework"): return (.failed, "sent back")
        case ("code_review", "block"): return (.failed, "blocked")
        case (_, "fail"), (_, "rework"), (_, "block"): return (.failed, outcome)
        default: return (.done, outcome.replacingOccurrences(of: "_", with: " "))
        }
    }

    /// How a run ended, in the run's own word: "handoff", "ended normally", "failed".
    static func exitState(_ exit: String?) -> (TicketPage.Step.Result, String) {
        guard let exit = exit?.trimmedNonEmpty else { return (.done, "ended") }
        let word = exit.replacingOccurrences(of: "_", with: " ")
        let lower = word.lowercased()
        if ["stopped", "canceled", "cancelled"].contains(where: lower.hasPrefix) { return (.stopped, word) }
        if lower.contains("fail") || lower.contains("error") || lower.contains("crash") { return (.failed, word) }
        return (.done, word)
    }

    static func runStep(
        _ run: Run, started: Date, children: [TicketPage.Step], reference: Date, clock: (Date) -> String
    ) -> TicketPage.Step {
        let (result, word) = runState(run)
        let ended = run.endedAt.flatMap(TicketPage.date)
        let end = ended ?? (run.status?.lowercased() == "running" ? reference : nil)
        return TicketPage.Step(
            id: "run-\(run.runID)", time: started, timeText: clock(started),
            title: runTitle(kind: run.runKind, number: run.runNumber), result: result, resultWord: word,
            durationSeconds: end.map { max(Int($0.timeIntervalSince(started)), 0) }, tokens: nil,
            detail: run.head.map { "on \($0.prefix(7))" }, runID: run.runID, children: children
        )
    }

    static func eventStep(_ event: Event, children: [TicketPage.Step], clock: (Date) -> String) -> TicketPage.Step {
        let at = event.at.flatMap(TicketPage.date) ?? Date(timeIntervalSince1970: 0)
        let personNote = event.type == "note" && event.actor?.kind == "person"
        let title = personNote ? TicketPage.noteByYou : event.summary?.title?.trimmedNonEmpty ?? event.type
        return TicketPage.Step(
            id: "event-\(event.id)", time: at, timeText: event.at == nil ? "" : clock(at), title: title,
            result: eventResult(event), resultWord: nil, durationSeconds: nil, tokens: nil,
            detail: event.summary?.detail?.trimmedNonEmpty, children: children,
            screenshots: event.artifacts.filter(\.isImage).map(\.screenshot)
        )
    }

    /// A finding failed, a verdict its outcome, a run's end its exit; anything else, a type the app doesn't know
    /// included, is done.
    static func eventResult(_ event: Event) -> TicketPage.Step.Result {
        switch event.type {
        case "finding.recorded": return .failed
        case "verdict.recorded": return event.payload.outcome.map { verdictState(kind: event.payload.kind, outcome: $0).0 } ?? .done
        case "run.ended": return exitState(event.payload.exit).0
        case "hold.set": return .stopped
        default: return .done
        }
    }

    // MARK: - Decoding

    private static func unique(_ events: [Event]) -> [Event] {
        var seen = Set<String>()
        return events.filter { seen.insert($0.id).inserted }
    }

    /// In the order Symphony wrote them: by `seq`, else by when they happened, else as they came.
    private static func ordered(_ events: [Event]) -> [Event] {
        events.enumerated().sorted { lhs, rhs in
            let left = lhs.element, right = rhs.element
            if let l = left.seq, let r = right.seq, l != r { return l < r }
            if left.seq == nil || right.seq == nil,
               let l = left.at.flatMap(TicketPage.date), let r = right.at.flatMap(TicketPage.date), l != r {
                return l < r
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    private struct Page: Decodable {
        let timeline: [Entry]
        let nextSince: String?
    }

    /// A top-level entry of the timeline: a run with its events, or an event of no run.
    private enum Entry: Decodable {
        case run(Run, [Node])
        case event(Node)

        enum CodingKeys: String, CodingKey {
            case kind, runId, runKind, runNumber, status, exit, verdict, startedAt, endedAt, head, events
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            guard try container.decodeIfPresent(String.self, forKey: .kind) == "run" else {
                self = .event(try Node(from: decoder))
                return
            }
            let run = Run(
                runID: try container.decode(String.self, forKey: .runId),
                runKind: try? container.decodeIfPresent(String.self, forKey: .runKind),
                runNumber: try? container.decodeIfPresent(Int.self, forKey: .runNumber),
                status: try? container.decodeIfPresent(String.self, forKey: .status),
                exit: try? container.decodeIfPresent(String.self, forKey: .exit),
                verdict: try? container.decodeIfPresent(Verdict.self, forKey: .verdict),
                startedAt: try? container.decodeIfPresent(String.self, forKey: .startedAt),
                endedAt: try? container.decodeIfPresent(String.self, forKey: .endedAt),
                head: try? container.decodeIfPresent(String.self, forKey: .head)
            )
            self = .run(run, try container.decodeIfPresent([Node].self, forKey: .events) ?? [])
        }
    }

    /// An event with the replies nested under it.
    private struct Node: Decodable {
        let event: Event
        let children: [Node]

        enum CodingKeys: String, CodingKey {
            case id, seq, at, type, runId, parent, actor, summary, payload, artifacts, children
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            event = Event(
                id: try container.decode(String.self, forKey: .id),
                seq: try? container.decodeIfPresent(Int.self, forKey: .seq),
                at: try? container.decodeIfPresent(String.self, forKey: .at),
                type: (try? container.decodeIfPresent(String.self, forKey: .type)) ?? "event",
                runID: try? container.decodeIfPresent(String.self, forKey: .runId),
                parent: try? container.decodeIfPresent(String.self, forKey: .parent),
                actor: try? container.decodeIfPresent(Actor.self, forKey: .actor),
                summary: try? container.decodeIfPresent(Summary.self, forKey: .summary),
                payload: (try? container.decodeIfPresent(Payload.self, forKey: .payload)) ?? Payload(),
                artifacts: (try? container.decodeIfPresent([Artifact].self, forKey: .artifacts)) ?? []
            )
            children = try container.decodeIfPresent([Node].self, forKey: .children) ?? []
        }

        var flattened: [Event] { [event] + children.flatMap(\.flattened) }
    }
}

// MARK: - Reading the feed

/// What a read of one page of a ticket's events feed got (`TicketEventsReader.Get`).
public enum TicketEventsResult: Equatable {
    case loaded(Data)
    /// The feed's own 404 (`ticket_not_found`): Symphony keeps no record of the ticket, which it writes when the
    /// ticket's first run starts.
    case unknownTicket
    /// Any other 404: the Symphony running predates the feed (`EndpointPlaceholder.updateSymphony`).
    case unsupported
    case failed(String)

    public init(_ answer: APIAnswer) {
        struct Payload: Decodable {
            struct Failure: Decodable {
                let code: String?
            }

            let error: Failure?
        }
        switch answer {
        case let .answered(data, 200):
            self = .loaded(data)
        case let .answered(data, 404):
            // An older Symphony has no such route: its 404 isn't the feed's own.
            let code = (try? JSONDecoder().decode(Payload.self, from: data))?.error?.code
            self = code == "ticket_not_found" ? .unknownTicket : .unsupported
        case let .answered(_, statusCode):
            self = .failed("Symphony answered with HTTP \(statusCode)")
        case .unreachable:
            self = .failed("Symphony isn't answering")
        }
    }
}

/// Why the reader holds no history of its ticket.
public enum TicketFeedAbsence: Equatable {
    /// Not read yet, or the last read failed: the next read may get it.
    case unread
    /// Symphony keeps no record of the ticket yet: it hasn't run. A later read gets its history once it has.
    case unknownTicket
    /// The Symphony running predates the feed. Nothing reads it again until the reader follows a ticket anew.
    case unsupported
}

/// Reads the shown ticket's events feed and keeps it current. It reads the whole feed when it starts following a
/// ticket, paging forward with `since`. Then it reads only what is newer than its cursor: on the live channel's notice
/// about its ticket, when the channel connects again, and, only while the channel isn't connected, after each state
/// poll. A notice that arrives while a read is out leads to one more read after it. A feed that answers 404, isn't
/// reachable or doesn't decode leaves `events` nil, so the page shows the timeline it builds without it.
@MainActor
public final class TicketEventsReader {
    public typealias Get = (_ path: String) async -> TicketEventsResult

    /// The most events one page asks for.
    public static let pageLimit = 200
    /// The most pages one read reads.
    public static let maxPages = 20

    public private(set) var identifier: String?
    public private(set) var repoKey: String?
    /// The history read so far; nil before the first read and after a read that failed.
    public private(set) var events: TicketEventsPayload?
    /// Why `events` is nil: `.unread` while it holds history too.
    public private(set) var absence: TicketFeedAbsence = .unread
    /// Symphony predates the feed. Nothing reads it again until the page follows a ticket anew.
    public var isUnsupported: Bool { absence == .unsupported }
    /// The live channel's state, as it was last told.
    public private(set) var channel: EventStreamState = .stopped
    /// Every path the reader asked for, oldest first.
    public private(set) var requests: [String] = []
    /// Told after a read that changed what it holds or why it holds none, and when it follows another ticket.
    public var onChange: (TicketEventsPayload?) -> Void = { _ in }

    private let get: Get
    private let pageLimit: Int
    private let maxPages: Int
    private var reading: Task<Void, Never>?
    private var readAgain = false
    /// Bumped when the reader follows another ticket, so a read for the one before changes nothing.
    private var generation = 0
    private var cancellables = Set<AnyCancellable>()

    public init(get: @escaping Get, pageLimit: Int = TicketEventsReader.pageLimit, maxPages: Int = TicketEventsReader.maxPages) {
        self.get = get
        self.pageLimit = pageLimit
        self.maxPages = maxPages
    }

    /// Follows ticket `identifier` of repo `repoKey`, nil for no ticket. Another ticket, or the same one once its repo
    /// is known, starts over with a full read; a nil repo key for the ticket it follows changes nothing. Returns
    /// whether a read started.
    @discardableResult
    public func follow(identifier: String?, repoKey: String?) -> Bool {
        if identifier == self.identifier, repoKey == nil || repoKey == self.repoKey { return false }
        generation += 1
        reading = nil
        readAgain = false
        let changed = events != nil || absence != .unread
        absence = .unread
        events = nil
        self.identifier = identifier
        self.repoKey = identifier == nil ? nil : repoKey
        if changed { onChange(nil) }
        return read() != nil
    }

    /// Listens to `stream`: its notices about the ticket followed and its reconnects.
    public func listen(to stream: EventStream) {
        cancellables.removeAll()
        stream.notices
            .sink { [weak self] notice in self?.noticed(notice) }
            .store(in: &cancellables)
        stream.$state
            .removeDuplicates()
            .sink { [weak self] state in self?.channelChanged(state) }
            .store(in: &cancellables)
    }

    /// Symphony wrote an event: read what is new when it is the followed ticket's.
    public func noticed(_ notice: EventStreamNotice) {
        guard let identifier, notice.issueIdentifier == identifier, notice.repoKey == nil || notice.repoKey == repoKey else { return }
        read()
    }

    /// The channel connected again: read what was written while it was down.
    public func channelChanged(_ state: EventStreamState) {
        let wasConnected = channel == .connected
        channel = state
        if state == .connected, !wasConnected { read() }
    }

    /// The window polled the state: read what is new, unless the channel is connected and says so itself.
    public func statePolled() {
        guard channel != .connected else { return }
        read()
    }

    /// Reads what is newer than the cursor (everything before the first read), or once more after the read out.
    @discardableResult
    public func read() -> Task<Void, Never>? {
        guard let identifier, let repoKey, !isUnsupported else { return nil }
        if reading != nil {
            readAgain = true
            return nil
        }
        let generation = generation
        let task = Task { await self.readPages(identifier: identifier, repoKey: repoKey, generation: generation) }
        reading = task
        return task
    }

    /// Waits for the reads out, the one queued after them included.
    public func settle() async {
        while let reading { await reading.value }
    }

    private func readPages(identifier: String, repoKey: String, generation: Int) async {
        var history = events ?? TicketEventsPayload()
        var failed = false
        var absence = TicketFeedAbsence.unread
        for _ in 0 ..< maxPages {
            let path = TicketPage.eventsPath(identifier, repoKey: repoKey, since: history.nextSince, limit: pageLimit)
            requests.append(path)
            let result = await get(path)
            guard generation == self.generation else { return }
            guard case let .loaded(data) = result, let page = TicketEventsPayload.decode(data) else {
                switch result {
                case .unknownTicket: absence = .unknownTicket
                case .unsupported: absence = .unsupported
                case .loaded, .failed: break
                }
                failed = true
                break
            }
            // A page that adds nothing, or a short one, is the last.
            if history.merge(page) == 0 || page.events.count < pageLimit { break }
        }
        reading = nil
        let found = failed ? nil : history
        // A read that found nothing new doesn't redraw the page; one that says why there is nothing does, so the page
        // can say it too.
        if found != events || absence != self.absence {
            events = found
            self.absence = absence
            onChange(found)
        }
        if readAgain {
            readAgain = false
            read()
        }
    }
}

// MARK: - Screenshots

/// The screenshots the timeline shows, read through the window's API client and kept by artifact id: an id is the
/// hash of its bytes, so what it names never changes.
@MainActor
public final class ArtifactImages: ObservableObject {
    public enum Image: Equatable {
        case loading
        case loaded(Data)
        /// Symphony no longer keeps it (`available: false`, a 404 or a 410), or its bytes aren't an image.
        case unavailable
        /// It couldn't be read just now; the next time it shows, it is read again.
        case failed
    }

    public typealias Get = (_ path: String) async -> APIAnswer

    /// How many images it keeps; past that the oldest goes.
    public static let capacity = 64

    @Published public private(set) var images: [String: Image] = [:]
    private var loadedOrder: [String] = []
    private let get: Get

    public init(get: @escaping Get) {
        self.get = get
    }

    /// What the thumbnail of `shot` shows now.
    public func image(_ shot: TicketScreenshot) -> Image {
        guard shot.available else { return .unavailable }
        return images[shot.id] ?? .loading
    }

    /// Reads `shot` unless it is kept, being read, or unavailable.
    @discardableResult
    public func load(_ shot: TicketScreenshot) -> Task<Void, Never>? {
        guard shot.available else { return nil }
        switch images[shot.id] {
        case .loading?, .loaded?, .unavailable?: return nil
        case .failed?, nil: break
        }
        images[shot.id] = .loading
        return Task {
            let answer = await get(shot.path)
            store(Self.image(answer), for: shot.id)
        }
    }

    /// What an answer to an artifact's GET shows.
    nonisolated static func image(_ answer: APIAnswer) -> Image {
        switch answer {
        case let .answered(data, 200):
            return isImage(data) ? .loaded(data) : .unavailable
        case .answered(_, 404), .answered(_, 410):
            return .unavailable
        case .answered, .unreachable:
            return .failed
        }
    }

    /// Whether `data` holds an image ImageIO reads.
    nonisolated static func isImage(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        return CGImageSourceGetCount(source) > 0 && CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
    }

    private func store(_ image: Image, for id: String) {
        images[id] = image
        guard case .loaded = image else { return }
        loadedOrder.append(id)
        while loadedOrder.count > Self.capacity {
            images[loadedOrder.removeFirst()] = nil
        }
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let trimmed = trimmingWhitespace()
        return trimmed.isEmpty ? nil : trimmed
    }
}
