import Foundation

/// What a stepped QA pass's step answered, as Symphony records it on the step's own `step.completed` payload: a check's
/// result, the plan, the rechecks a review asks for, a review's verdict in words. Every field is optional and a shape
/// this app does not know is skipped; a step with none of them has no answer.
public struct StepAnswer: Equatable {
    /// A check step's result: what it expected, what it saw, and its status in Symphony's word ("passed", "blocked").
    public struct Result: Equatable {
        public var status: String?
        public var expected: String?
        public var actual: String?

        /// The status when it says more than the step's own state does ("blocked"); nil for "passed" and "failed".
        public var extraWord: String? {
            guard let status = status?.lowercased(), !Self.plain.contains(status) else { return nil }
            return status
        }

        static let plain: Set<String> = ["passed", "failed", "done", "ok", "pass", "fail"]
    }

    /// The plan step's plan: a summary, what it will check and what it will not.
    public struct Plan: Equatable {
        public struct Check: Equatable {
            public var title: String
            public var expect: String?
        }

        public struct Skip: Equatable {
            public var title: String
            public var why: String?
        }

        public var summary: String?
        public var checks: [Check]
        public var skips: [Skip]
    }

    /// One check the review asks to run again.
    public struct Recheck: Equatable {
        public var title: String
        /// What to do, step by step.
        public var instructions: [String]
        public var expect: String?
        public var design: String?
    }

    public var result: Result?
    public var plan: Plan?
    public var rechecks: [Recheck]
    /// The final review's verdict in words.
    public var verdictSummary: String?

    public init(result: Result? = nil, plan: Plan? = nil, rechecks: [Recheck] = [], verdictSummary: String? = nil) {
        self.result = result
        self.plan = plan
        self.rechecks = rechecks
        self.verdictSummary = verdictSummary
    }

    /// The answer a step's payload holds; nil when it holds none.
    init?(fields: BlockFields) {
        let result = fields.map("result").flatMap { map -> Result? in
            let read = Result(status: map.text("status"), expected: map.text("expected"), actual: map.text("actual"))
            return read.status == nil && read.expected == nil && read.actual == nil ? nil : read
        }
        let plan = fields.map("plan").flatMap { map -> Plan? in
            let checks = map.list("checks").compactMap { check in
                check.text("title").map { Plan.Check(title: $0, expect: check.text("expect")) }
            }
            let skips = map.list("skips").compactMap { skip in
                skip.text("title").map { Plan.Skip(title: $0, why: skip.text("why")) }
            }
            let read = Plan(summary: map.text("summary"), checks: checks, skips: skips)
            return read.summary == nil && checks.isEmpty && skips.isEmpty ? nil : read
        }
        let rechecks = fields.list("recheck").compactMap { item -> Recheck? in
            guard let title = item.text("title") else { return nil }
            return Recheck(title: title, instructions: item.strings("do"), expect: item.text("expect"), design: item.text("design"))
        }
        let answer = StepAnswer(result: result, plan: plan, rechecks: rechecks, verdictSummary: fields.text("verdictSummary"))
        guard !answer.isEmpty else { return nil }
        self = answer
    }

    public var isEmpty: Bool { result == nil && plan == nil && rechecks.isEmpty && verdictSummary == nil }
}
