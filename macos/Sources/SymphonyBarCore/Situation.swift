import Foundation

/// A ticket's situation as the ticket read serves it (`docs/control-api.md` § `situation`): one kind from the closed
/// vocabulary of `director-ticket-page.md` §3, its word, its cause, what moves it next and since when. Symphony
/// computes it; the app only says it.
public struct Situation: Equatable, Decodable {
    /// For `working` when a step is open.
    public struct Step: Equatable, Decodable {
        public var id: String
        public var title: String?

        public init(id: String, title: String? = nil) {
            self.id = id
            self.title = title
        }
    }

    /// For `working`: the run, by its label (`Implementation run 2`).
    public struct Run: Equatable, Decodable {
        public var id: String?
        public var kind: String?
        public var number: Int?
        public var label: String

        public init(id: String? = nil, kind: String? = nil, number: Int? = nil, label: String) {
            self.id = id
            self.kind = kind
            self.number = number
            self.label = label
        }
    }

    /// For `retrying`: try k of n (n is nil past the limit) and when it starts.
    public struct Retry: Equatable, Decodable {
        public var attempt: Int
        public var of: Int?
        public var at: Date?

        public init(attempt: Int, of: Int? = nil, at: Date? = nil) {
            self.attempt = attempt
            self.of = of
            self.at = at
        }

        private enum CodingKeys: String, CodingKey { case attempt = "try", of, at }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            attempt = try container.decode(Int.self, forKey: .attempt)
            of = try container.decodeIfPresent(Int.self, forKey: .of)
            at = try container.decodeIfPresent(String.self, forKey: .at).flatMap(SymphonyState.parseDate)
        }
    }

    public var kind: DesignTokens.SituationKind
    public var word: String
    public var cause: String
    public var next: String?
    public var since: Date?
    /// The pause's further reasons, which the paused line lists.
    public var andMore: Int
    public var step: Step?
    public var run: Run?
    public var retry: Retry?

    public init(
        kind: DesignTokens.SituationKind, word: String? = nil, cause: String, next: String? = nil, since: Date? = nil,
        andMore: Int = 0, step: Step? = nil, run: Run? = nil, retry: Retry? = nil
    ) {
        self.kind = kind
        self.word = word ?? kind.word
        self.cause = cause
        self.next = next
        self.since = since
        self.andMore = andMore
        self.step = step
        self.run = run
        self.retry = retry
    }

    private enum CodingKeys: String, CodingKey { case kind, word, cause, next, since, andMore = "and_more", step, run, retry }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decode(String.self, forKey: .kind)
        guard let kind = DesignTokens.SituationKind(apiKind: name) else {
            throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "No situation kind \(name)")
        }
        self.kind = kind
        word = try container.decodeIfPresent(String.self, forKey: .word) ?? kind.word
        cause = try container.decodeIfPresent(String.self, forKey: .cause) ?? ""
        next = try container.decodeIfPresent(String.self, forKey: .next)
        since = try container.decodeIfPresent(String.self, forKey: .since).flatMap(SymphonyState.parseDate)
        andMore = try container.decodeIfPresent(Int.self, forKey: .andMore) ?? 0
        step = try container.decodeIfPresent(Step.self, forKey: .step)
        run = try container.decodeIfPresent(Run.self, forKey: .run)
        retry = try container.decodeIfPresent(Retry.self, forKey: .retry)
    }

    /// The `situation` object as JSON; nil for anything else, or a kind outside the vocabulary.
    public static func decode(_ data: Data) -> Situation? {
        try? JSONDecoder().decode(Situation.self, from: data)
    }

    /// The `situation` value of a decoded JSON entry (a ticket read, an entry of `/state`'s `issues`).
    public static func decode(object: Any?) -> Situation? {
        guard let object, JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object)
        else { return nil }
        return decode(data)
    }
}

extension DesignTokens.SituationKind {
    /// The kind's name in the API (`waiting_for_ci`).
    public var apiKind: String {
        switch self {
        case .you: "waiting_on_you"
        case .retrying: "retrying"
        case .blocked: "blocked_by_ticket"
        case .paused: "paused_by_rule"
        case .ci: "waiting_for_ci"
        case .build: "waiting_for_build"
        case .slot: "waiting_for_slot"
        case .working: "working"
        case .done: "done"
        case .cancelled: "cancelled"
        }
    }

    public init?(apiKind: String) {
        guard let kind = Self.allCases.first(where: { $0.apiKind == apiKind }) else { return nil }
        self = kind
    }
}

/// The Situation line's words (`director-ticket-page.md` §3): the word, the cause (with "and n more" when a pause has
/// further reasons), what moves it next and since when, and the one sentence VoiceOver reads.
public struct SituationText: Equatable {
    public var kind: DesignTokens.SituationKind
    public var word: String
    public var cause: String
    public var next: String?
    /// The age as a row shows it, trailing: "6 min", or "2 days ago" once cancelled; nil for a shipped ticket and when
    /// no fact says since when.
    public var age: String?
    /// The age as the full line shows it beside the word: "for 6 min", or "2 days ago".
    public var ageLabel: String?
    /// The age as VoiceOver says it: "for 6 minutes", "2 days ago".
    public var spokenAge: String?

    public init(_ situation: Situation, reference: Date) {
        kind = situation.kind
        word = situation.word.isEmpty ? situation.kind.word : situation.word
        cause = Self.cause(situation.cause, andMore: situation.andMore)
        next = situation.next.flatMap { $0.isEmpty ? nil : $0 }
        let seconds = situation.since.map { max(Int(reference.timeIntervalSince($0)), 0) }
        switch (situation.kind, seconds) {
        case (.done, _), (_, nil):
            age = nil
            ageLabel = nil
            spokenAge = nil
        case let (.cancelled, seconds?):
            age = "\(Overview.duration(seconds)) ago"
            ageLabel = age
            spokenAge = "\(Overview.spokenDuration(seconds)) ago"
        case let (_, seconds?):
            age = Overview.duration(seconds)
            ageLabel = "for \(Overview.duration(seconds))"
            spokenAge = "for \(Overview.spokenDuration(seconds))"
        }
    }

    /// "Dispatch is paused: Deploy freeze, and 2 more." for a pause with two further reasons.
    static func cause(_ cause: String, andMore: Int) -> String {
        guard andMore > 0 else { return cause }
        let trimmed = cause.trimmingCharacters(in: .whitespaces)
        let stem = trimmed.hasSuffix(".") ? String(trimmed.dropLast()) : trimmed
        return stem.isEmpty ? "And \(andMore) more." : "\(stem), and \(andMore) more."
    }

    /// The line as the design's table writes it: "Waiting for CI · Checks are running on PR #741. · Code Review starts
    /// when they pass. · for 6 min".
    public var sentence: String {
        [word, cause, next, ageLabel].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// What VoiceOver reads: the word, the age and the cause as one sentence ("Waiting for CI, for 6 minutes: Checks are
    /// running on PR #741."), then Forced when the ticket is.
    public func spoken(forced: Bool = false) -> String {
        let head = [word, spokenAge].compactMap { $0 }.joined(separator: ", ")
        let line = cause.isEmpty ? "\(head)." : "\(head): \(cause)"
        return forced ? "\(line) Forced." : line
    }
}
