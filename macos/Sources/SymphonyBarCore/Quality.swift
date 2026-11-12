import Foundation

/// The `review` part of `GET /api/v1/history`: how far the Code Review agent can be trusted. The acceptance gate
/// is retired; a Code Review approval is upheld when QA passes it or the Director confirms the merge, and overturned
/// when QA fails it or the Director sends it to Rework.
public struct ReviewHistory: Equatable {
    /// Approvals upheld, overturned and not judged yet.
    public struct Agreement: Equatable {
        public var agreed: Int
        public var disagreed: Int
        public var pending: Int

        public init(agreed: Int = 0, disagreed: Int = 0, pending: Int = 0) {
            self.agreed = agreed
            self.disagreed = disagreed
            self.pending = pending
        }

        public var judged: Int { agreed + disagreed }
        /// Agreed over judged; nil before any approval was judged.
        public var rate: Double? { judged > 0 ? Double(agreed) / Double(judged) : nil }
    }

    /// A repo's agreement, with its manual review setting.
    public struct Repo: Equatable {
        public var repoKey: String
        public var manualReview: ManualReviewChoice
        public var agreement: Agreement

        public init(repoKey: String, manualReview: ManualReviewChoice = .off, agreement: Agreement) {
            self.repoKey = repoKey
            self.manualReview = manualReview
            self.agreement = agreement
        }
    }

    /// An approval QA or the Director overturned.
    public struct Disagreement: Equatable {
        public var identifier: String
        public var repoKey: String?
        public var review: String
        public var decision: String
        public var decidedBy: String

        public init(identifier: String, repoKey: String? = nil, review: String = "Approved", decision: String, decidedBy: String) {
            self.identifier = identifier
            self.repoKey = repoKey
            self.review = review
            self.decision = decision
            self.decidedBy = decidedBy
        }
    }

    public var agreement: Agreement
    public var byRepo: [Repo]
    /// Tickets whose first QA verdict was a pass, of the tickets QA judged.
    public var qaFirstPass: (passed: Int, judged: Int)
    /// Reviewed tickets sent back to Rework, of the tickets reviewed.
    public var sentToRework: (sent: Int, reviewed: Int)
    public var disagreements: [Disagreement]

    public init(
        agreement: Agreement = Agreement(),
        byRepo: [Repo] = [],
        qaFirstPass: (passed: Int, judged: Int) = (0, 0),
        sentToRework: (sent: Int, reviewed: Int) = (0, 0),
        disagreements: [Disagreement] = []
    ) {
        self.agreement = agreement
        self.byRepo = byRepo
        self.qaFirstPass = qaFirstPass
        self.sentToRework = sentToRework
        self.disagreements = disagreements
    }

    public static func == (lhs: ReviewHistory, rhs: ReviewHistory) -> Bool {
        lhs.agreement == rhs.agreement && lhs.byRepo == rhs.byRepo && lhs.disagreements == rhs.disagreements
            && lhs.qaFirstPass == rhs.qaFirstPass && lhs.sentToRework == rhs.sentToRework
    }

    struct Payload: Decodable {
        struct Counts: Decodable {
            let agreed: Int?
            let disagreed: Int?
            let pending: Int?
            let repoKey: String?
            let manualReview: String?
        }

        struct Ratio: Decodable {
            let passed: Int?
            let judged: Int?
            let sent: Int?
            let reviewed: Int?
        }

        struct Disagreement: Decodable {
            let identifier: String?
            let issueId: String?
            let repoKey: String?
            let review: String?
            let decision: String?
            let decidedBy: String?
        }

        let agreement: Counts?
        let byRepo: [Counts]?
        let qaFirstPass: Ratio?
        let sentToRework: Ratio?
        let disagreements: [Disagreement]?

        var review: ReviewHistory {
            ReviewHistory(
                agreement: Self.agreement(agreement),
                byRepo: (byRepo ?? []).compactMap { repo in
                    repo.repoKey.map {
                        ReviewHistory.Repo(repoKey: $0, manualReview: ManualReviewChoice(rawValue: repo.manualReview ?? "") ?? .off, agreement: Self.agreement(repo))
                    }
                },
                qaFirstPass: (qaFirstPass?.passed ?? 0, qaFirstPass?.judged ?? 0),
                sentToRework: (sentToRework?.sent ?? 0, sentToRework?.reviewed ?? 0),
                disagreements: (disagreements ?? []).compactMap { row -> ReviewHistory.Disagreement? in
                    guard let identifier = row.identifier ?? row.issueId, let decision = row.decision else { return nil }
                    return ReviewHistory.Disagreement(
                        identifier: identifier, repoKey: row.repoKey, review: row.review ?? "Approved", decision: decision,
                        decidedBy: row.decidedBy ?? "QA"
                    )
                }
            )
        }

        static func agreement(_ counts: Counts?) -> ReviewHistory.Agreement {
            ReviewHistory.Agreement(agreed: counts?.agreed ?? 0, disagreed: counts?.disagreed ?? 0, pending: counts?.pending ?? 0)
        }
    }
}

/// A run as `GET /api/v1/runs` lists it, for Quality's runs by outcome and Show All Runs.
public struct QualityRun: Equatable, Identifiable {
    public static let path = "api/v1/runs"
    /// The most runs `/api/v1/runs` returns in one read.
    public static let limit = 500

    public enum Outcome: String, CaseIterable, Equatable, Comparable {
        case prOpened = "pr_opened"
        case noChanges = "no_changes"
        case error

        public init(_ raw: String?) {
            self = raw.flatMap(Outcome.init(rawValue:)) ?? .noChanges
        }

        public var title: String {
            switch self {
            case .prOpened: "Opened a PR"
            case .noChanges: "No changes"
            case .error: "Failed"
            }
        }

        /// The outcome's status color (design system §3.3): runs by outcome is a status chart, not a series one.
        public var status: DesignTokens.Status {
            switch self {
            case .prOpened: .done
            case .noChanges: .idle
            case .error: .problem
            }
        }

        public static func < (lhs: Outcome, rhs: Outcome) -> Bool {
            allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
        }
    }

    public var id: String
    public var identifier: String?
    public var agent: String
    public var outcome: Outcome
    /// The UTC day the run was logged, "2026-10-13".
    public var date: String
    public var tokens: Int
    public var durationSeconds: Int

    public init(id: String, identifier: String? = nil, agent: String = "unknown", outcome: Outcome, date: String, tokens: Int = 0, durationSeconds: Int = 0) {
        self.id = id
        self.identifier = identifier
        self.agent = agent
        self.outcome = outcome
        self.date = date
        self.tokens = tokens
        self.durationSeconds = durationSeconds
    }

    /// The path that asks for the runs logged since `from` (a UTC day).
    public static func path(from: String) -> String { "\(path)?date_from=\(from)&limit=\(limit)" }

    /// The runs in a payload, nil when it isn't one.
    public static func decode(_ data: Data) -> [QualityRun]? {
        guard let payload = try? InboxPayload.decoder.decode(Payload.self, from: data), let runs = payload.runs else { return nil }
        return runs.enumerated().compactMap { index, run in
            guard let date = run.date else { return nil }
            return QualityRun(
                id: run.evalId ?? run.runId ?? "run-\(index)", identifier: run.issueIdentifier, agent: run.agentKind ?? "unknown",
                outcome: Outcome(run.outcome), date: date, tokens: run.tokens?.totalTokens ?? 0, durationSeconds: run.durationSeconds ?? 0
            )
        }
    }

    struct Payload: Decodable {
        struct Run: Decodable {
            struct Tokens: Decodable { let totalTokens: Int? }
            let evalId: String?
            let runId: String?
            let issueIdentifier: String?
            let agentKind: String?
            let outcome: String?
            let date: String?
            let tokens: Tokens?
            let durationSeconds: Int?
        }

        let runs: [Run]?
    }
}

/// D7: how far to trust the crew over the Insights slice (TP-1463). Four tiles, runs by outcome and verdicts per bucket
/// from the aggregation, review agreement by repo and the disagreements from the history's review, and every run.
public struct Quality: Equatable {
    /// C5: a figure, its label and one line of context.
    public struct Tile: Equatable, Identifiable {
        public var id: String { title }
        public var title: String
        public var value: String
        public var context: String
        public var isEmpty: Bool
    }

    /// A repo's bar in Review agreement by repo.
    public struct RepoBar: Equatable, Identifiable {
        public var id: String { repoKey }
        public var repoKey: String
        /// From 0 to 1; nil before any approval was judged.
        public var rate: Double?
        /// "Manual review on".
        public var mode: String
        /// "9 of 10 upheld".
        public var value: String
    }

    /// A row of Disagreements: both decisions.
    public struct DisagreementRow: Equatable, Identifiable {
        public var id: String { identifier }
        public var identifier: String
        public var repoKey: String?
        /// "Code Review: Approved".
        public var review: String
        /// "QA: QA failed" or "Director: Sent to Rework".
        public var decision: String
    }

    public static let agreementTitle = "Review agreement by repo"
    public static let disagreementsTitle = "Disagreements"
    public static let showAllRunsTitle = "Show All Runs"
    public static let changeReviewTitle = "Change Review…"
    public static let showDataTitle = "Show Data"

    public var tiles: [Tile]
    public var repos: [RepoBar]
    /// Runs started per bucket, stacked by how they ended, in status colors.
    public var runsChart: InsightsChart
    /// Verdicts recorded per bucket: approvals and passes against what was sent back or failed.
    public var verdictsChart: InsightsChart
    public var disagreements: [DisagreementRow]
    /// The runs of the period's days, newest first, for Show All Runs.
    public var runs: [QualityRun]
    /// Nil while the slice has a run or a verdict.
    public var empty: InsightsEmpty?

    public init(
        aggregate: AggregatePayload, slice: InsightsSlice, scope: OverviewScope = .all, review: ReviewHistory?, runs allRuns: [QualityRun],
        today: String
    ) {
        let (from, to) = slice.period.days(today: today)
        runs = allRuns.filter { $0.date >= from && $0.date <= to }.sorted { ($0.date, $0.id) > ($1.date, $1.id) }
        runsChart = InsightsChart.build(
            aggregate.runs, unit: aggregate.unit, title: "Runs \(aggregate.unit.per)", measure: "Runs", format: .count, fallback: "other",
            order: Self.runKeys.map(\.key), key: Self.runKey
        )
        verdictsChart = InsightsChart.build(
            aggregate.verdicts, unit: aggregate.unit, title: "Verdicts \(aggregate.unit.per)", measure: "Verdicts", format: .count,
            fallback: "other", order: Self.verdictKeys.map(\.key), key: Self.verdictKey
        )

        let repoKey = slice.repoKey(scope: scope)
        let review = review ?? ReviewHistory()
        let byRepo = review.byRepo.filter { repo in repoKey.map { repo.repoKey == $0 } ?? true }
        let agreement = repoKey == nil ? review.agreement : (byRepo.first?.agreement ?? ReviewHistory.Agreement())
        let runsBy = aggregate.runs.by
        let verdicts = aggregate.verdicts.by
        let codeReview = verdicts.filter { $0.key.hasPrefix("code_review:") }.values.reduce(0, +)
        let qa = verdicts.filter { $0.key.hasPrefix("qa:") }.values.reduce(0, +)
        let runCount = runsBy.values.reduce(0, +)
        tiles = [
            Self.tile("Runs that succeeded", Self.rate(runsBy["success"] ?? 0, runCount), of: runCount, context: "runs"),
            Self.tile("Code Review approvals", Self.rate(verdicts["code_review:approve"] ?? 0, codeReview), of: codeReview, context: "Code Review verdicts"),
            Self.tile("QA passes", Self.rate(verdicts["qa:pass"] ?? 0, qa), of: qa, context: "QA verdicts"),
            Self.tile("Review agreement", agreement.rate, of: agreement.judged, context: "judged Code Review approvals"),
        ]
        repos = byRepo.map { repo in
            RepoBar(
                repoKey: repo.repoKey, rate: repo.agreement.rate, mode: "Manual review \(repo.manualReview.title.lowercased())",
                value: repo.agreement.judged > 0 ? "\(repo.agreement.agreed) of \(repo.agreement.judged) upheld" : "Nothing judged yet"
            )
        }
        disagreements = review.disagreements
            .filter { row in repoKey.map { row.repoKey == $0 } ?? true }
            .map { row in
                DisagreementRow(
                    identifier: row.identifier, repoKey: row.repoKey, review: "Code Review: \(row.review)", decision: "\(row.decidedBy): \(row.decision)"
                )
            }
        empty = runsChart.total + verdictsChart.total > 0 ? nil : slice.empty("No runs or verdicts", today: today)
    }

    /// How a run ended, as its status color says it (design system §3.3): a status chart, not a series one.
    static let runKeys: [InsightsChart.Key] = [
        .init(key: "success", name: "Succeeded", tint: .status(.done)),
        .init(key: "failure", name: "Failed", tint: .status(.problem)),
        .init(key: "timeout", name: "Timed out", tint: .status(.you)),
        .init(key: "stopped", name: "Stopped", tint: .status(.idle)),
        .init(key: "other", name: "Other", tint: .status(.working)),
    ]

    /// A run record's status as its stacked key: `cancelled` reads as stopped, any other unknown one as Other.
    public static func runKey(_ raw: String) -> InsightsChart.Key {
        let key = ["stopped", "cancelled", "canceled"].contains(raw) ? "stopped" : raw
        return runKeys.first { $0.key == key } ?? runKeys[runKeys.count - 1]
    }

    /// A verdict, `kind:outcome`, by what it did to the work.
    static let verdictKeys: [InsightsChart.Key] = [
        .init(key: "upheld", name: "Approved or passed", tint: .status(.done)),
        .init(key: "returned", name: "Sent back or failed", tint: .status(.problem)),
        .init(key: "other", name: "Other", tint: .status(.idle)),
    ]

    /// `code_review:approve` and `qa:pass` let the work on; `request_changes`, `block`, `fail` and `rework` send it back.
    public static func verdictKey(_ raw: String) -> InsightsChart.Key {
        let outcome = raw.split(separator: ":").last.map(String.init) ?? raw
        switch outcome {
        case "approve", "pass": return verdictKeys[0]
        case "request_changes", "block", "fail", "rework", "changes": return verdictKeys[1]
        default: return verdictKeys[2]
        }
    }

    /// Show Data's table for review agreement by repo.
    public var agreementTable: [[String]] {
        [["Repo", "Mode", "Agreement", "Upheld"]] + repos.map { [$0.repoKey, $0.mode, Self.percent($0.rate), $0.value] }
    }

    /// The agreement chart's accessibility summary.
    public var agreementSummary: String {
        guard !repos.isEmpty else { return "No Code Review approval in this period." }
        return repos.map { "\($0.repoKey): \(Self.percent($0.rate)), \($0.value), \($0.mode)" }.joined(separator: ". ") + "."
    }

    /// Show All Runs' filters.
    public struct RunFilter: Equatable {
        public var agent: String?
        public var outcome: QualityRun.Outcome?
        public var date: String?

        public init(agent: String? = nil, outcome: QualityRun.Outcome? = nil, date: String? = nil) {
            self.agent = agent
            self.outcome = outcome
            self.date = date
        }
    }

    /// The agents the period's runs name, for the agent filter.
    public var agents: [String] { Set(runs.map(\.agent)).sorted() }

    /// The days the period has runs on, newest first, for the date filter.
    public var runDates: [String] { Set(runs.map(\.date)).sorted(by: >) }

    /// The period's runs that `filter` keeps.
    public func runs(matching filter: RunFilter) -> [QualityRun] {
        runs.filter { run in
            (filter.agent.map { run.agent == $0 } ?? true) && (filter.outcome.map { run.outcome == $0 } ?? true)
                && (filter.date.map { run.date == $0 } ?? true)
        }
    }

    /// "86%", or "—" without a rate.
    public static func percent(_ rate: Double?) -> String {
        rate.map { "\(Int(($0 * 100).rounded()))%" } ?? "—"
    }

    static func rate(_ count: Int, _ total: Int) -> Double? {
        total > 0 ? Double(count) / Double(total) : nil
    }

    static func tile(_ title: String, _ rate: Double?, of total: Int, context: String) -> Tile {
        Tile(title: title, value: percent(rate), context: total > 0 ? "\(total) \(context)" : "Nothing to count yet", isEmpty: rate == nil)
    }

    static func isoDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
