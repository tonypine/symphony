import Foundation

// The plan on top of a groomed ticket's page, in the Brief panel's place: what Grooming planned, in the Conductor's
// summary, then the plan's checks, one line each with its state and how it is proved. Its title line says how far the
// checks are ("3 of 5 checks proved"); unfolded it shows the plan as the runs read it and what was asked. A ticket
// with no plan keeps the Brief panel (`BriefPanelModel`).

// MARK: - The ticket read

/// The ticket read's `plan`: the current plan without its checks, with its `version` and `at`.
public struct TicketPlanRead: Equatable, Decodable {
    public var version: Int?
    public var at: Date?
    /// Why this version was written: "Grooming" for the first.
    public var reason: String?
    /// Who wrote it: `grooming`, `recalibration`, `parent` or `run`.
    public var by: String?
    /// `single` or `split`.
    public var shape: String?
    public var layers: [String]
    /// The plan in a few sentences, for a person.
    public var summary: String
    /// The plan as the runs read it.
    public var text: String

    public init(
        version: Int? = nil, at: Date? = nil, reason: String? = nil, by: String? = nil, shape: String? = nil, layers: [String] = [],
        summary: String = "", text: String = ""
    ) {
        self.version = version
        self.at = at
        self.reason = reason
        self.by = by
        self.shape = shape
        self.layers = layers
        self.summary = summary
        self.text = text
    }

    private enum CodingKeys: String, CodingKey { case version, at, reason, by, shape, layers, summary, text }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func text(_ key: CodingKeys) -> String? { (try? container.decodeIfPresent(String.self, forKey: key)) ?? nil }
        self.init(
            version: (try? container.decodeIfPresent(Int.self, forKey: .version)) ?? nil,
            at: text(.at).flatMap(SymphonyState.parseDate), reason: text(.reason), by: text(.by), shape: text(.shape),
            layers: ((try? container.decodeIfPresent([String].self, forKey: .layers)) ?? nil) ?? [],
            summary: text(.summary) ?? "", text: text(.text) ?? ""
        )
    }
}

/// One of the ticket read's `checks`: a check of the current plan with its `state` and, once proved, `proved_by`.
public struct TicketCheckRead: Equatable, Decodable, Identifiable {
    /// Where a check stands. A state this app does not know reads as open.
    public enum State: String, Equatable {
        case open, proved, waived
    }

    /// What proved it (`proved_by`, a `check.proved`'s fields): how (`by`), the test's name and what it says.
    public struct Proof: Equatable, Decodable {
        public var by: String?
        public var test: String?
        public var details: String?

        public init(by: String? = nil, test: String? = nil, details: String? = nil) {
            self.by = by
            self.test = test
            self.details = details
        }

        private enum CodingKeys: String, CodingKey { case by, test, details }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            func text(_ key: CodingKeys) -> String? { (try? container.decodeIfPresent(String.self, forKey: key)) ?? nil }
            self.init(by: text(.by), test: text(.test), details: text(.details))
        }
    }

    /// "c1": the same across the plan's versions.
    public var id: String
    /// `outcome`, `qa` or `evidence`.
    public var kind: String?
    public var statement: String
    /// How it is to be proved: `test`, `qa`, `design` or `attached`.
    public var proof: String?
    public var state: State
    public var provedBy: Proof?

    public init(id: String, kind: String? = nil, statement: String, proof: String? = nil, state: State = .open, provedBy: Proof? = nil) {
        self.id = id
        self.kind = kind
        self.statement = statement
        self.proof = proof
        self.state = state
        self.provedBy = provedBy
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, statement, proof, state
        case provedBy = "proved_by"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func text(_ key: CodingKeys) -> String? { (try? container.decodeIfPresent(String.self, forKey: key)) ?? nil }
        let provedBy = (try? container.decodeIfPresent(Proof.self, forKey: .provedBy)) ?? nil
        // A state that is none of the three is open, unless the check names what proved it.
        let state = text(.state).flatMap(State.init(rawValue:)) ?? (provedBy == nil ? .open : .proved)
        self.init(
            id: try container.decode(String.self, forKey: .id), kind: text(.kind), statement: text(.statement) ?? "", proof: text(.proof),
            state: state, provedBy: provedBy
        )
    }
}

/// One of the ticket read's `asks`: what a person asked, as written, oldest first.
public struct TicketAskRead: Equatable, Decodable {
    public var text: String
    /// Where it came from: `linear`, `message` or `parent`.
    public var source: String?
    /// The parent ticket, or the message's event.
    public var from: String?
    public var at: Date?

    public init(text: String, source: String? = nil, from: String? = nil, at: Date? = nil) {
        self.text = text
        self.source = source
        self.from = from
        self.at = at
    }

    private enum CodingKeys: String, CodingKey { case text, source, from, at }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func text(_ key: CodingKeys) -> String? { (try? container.decodeIfPresent(String.self, forKey: key)) ?? nil }
        self.init(text: text(.text) ?? "", source: text(.source), from: text(.from), at: text(.at).flatMap(SymphonyState.parseDate))
    }
}

/// A list read one item at a time: an item that does not read is left out, and anything but a list is empty.
struct LossyList<Item: Decodable>: Decodable {
    var items: [Item]

    private struct Slot: Decodable {
        var item: Item?

        init(from decoder: Decoder) throws { item = try? Item(from: decoder) }
    }

    init(from decoder: Decoder) throws {
        items = ((try? decoder.singleValueContainer().decode([Slot].self)) ?? []).compactMap(\.item)
    }
}

// MARK: - The panel

/// What the Plan panel says.
public struct PlanPanelModel: Equatable {
    /// One check's line: its state's mark, its statement and how it is proved.
    public struct Check: Equatable, Identifiable {
        public var id: String
        public var statement: String
        public var state: TicketCheckRead.State
        /// "Test", "QA", "Design", "Attached"; "Waived" for a waived one; nil when the plan names no proof.
        public var proof: String?
        /// The test that proved it and what the proof says, under the pointer.
        public var help: String?

        /// The state's glyph.
        public var symbol: String {
            switch state {
            case .open: "circle"
            case .proved: "checkmark.circle.fill"
            case .waived: "minus.circle"
            }
        }

        /// The state in a word, for VoiceOver.
        public var stateWord: String {
            switch state {
            case .open: "Open"
            case .proved: "Proved"
            case .waived: "Waived"
            }
        }

        /// "Proved, The line says why the ticket is paused, Test".
        public var accessibilityLabel: String {
            [stateWord, statement, state == .waived ? nil : proof].compactMap { $0 }.joined(separator: ", ")
        }
    }

    /// "Plan".
    public var title: String
    /// "3 of 5 checks proved"; nil for a plan with no checks.
    public var note: String?
    /// The plan's summary, the panel's opening text; nil when it has none.
    public var summary: String?
    public var checks: [Check]
    /// The plan as the runs read it, shown unfolded.
    public var text: String?
    /// What was asked, every ask in order, shown unfolded.
    public var asked: String?

    public static let title = "Plan"
    public static let textTitle = "Plan for the runs"
    public static let readAllTitle = "Read the whole plan"
    public static let waived = "Waived"

    /// Whether the panel has a fold: only a plan with text for the runs, or an ask, does.
    public var folds: Bool { text != nil || asked != nil }

    /// Nothing to draw: a plan with no summary, no checks and nothing under its fold.
    public var isEmpty: Bool { summary == nil && checks.isEmpty && !folds }

    /// The panel in one line: "Plan · 3 of 5 checks proved".
    public var line: String { [title, note].compactMap { $0 }.joined(separator: " · ") }

    /// The fold control's title as it reads while `open`.
    public static func foldTitle(open: Bool) -> String { open ? BriefPanelModel.showLessTitle : readAllTitle }

    /// "3 of 5 checks proved", "1 of 1 check proved"; nil without checks.
    public static func progress(_ checks: [TicketCheckRead]) -> String? {
        guard !checks.isEmpty else { return nil }
        let proved = checks.count(where: { $0.state == .proved })
        return "\(proved) of \(checks.count) \(checks.count == 1 ? "check" : "checks") proved"
    }

    /// How a check is proved, in a word: "Test", "QA", "Design", "Attached"; nil for a proof this app does not know.
    public static func proofWord(_ proof: String?) -> String? {
        switch proof {
        case "test": "Test"
        case "qa": "QA"
        case "design": "Design"
        case "attached": "Attached"
        default: nil
        }
    }

    /// The panel from the ticket read; nil for a ticket with no plan, which keeps the Brief panel.
    public static func build(_ read: TicketDetailsRead?) -> PlanPanelModel? {
        guard let read, let plan = read.plan else { return nil }
        let asks = read.asks.map { $0.text.trimmingWhitespace() }.filter { !$0.isEmpty }.map(BriefPanelModel.prose(of:))
        return PlanPanelModel(
            title: title, note: progress(read.checks), summary: plan.summary.trimmingWhitespace().nonEmpty,
            checks: read.checks.map(check), text: BriefPanelModel.prose(of: plan.text).nonEmpty,
            asked: asks.joined(separator: "\n\n").nonEmpty
        )
    }

    static func check(_ read: TicketCheckRead) -> Check {
        // A proved check says what proved it; an open one how it is to be proved.
        let proof = read.state == .waived ? waived : proofWord(read.provedBy?.by) ?? proofWord(read.proof)
        let help = [read.provedBy?.test, read.provedBy?.details].compactMap { $0?.trimmingWhitespace().nonEmpty }.joined(separator: "\n")
        return Check(id: read.id, statement: read.statement.trimmingWhitespace(), state: read.state, proof: proof, help: help.nonEmpty)
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
