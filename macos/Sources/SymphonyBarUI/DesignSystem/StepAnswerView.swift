import SwiftUI
import SymphonyBarCore

/// What a QA step answered, above its lines when the step unfolds: a check's expected and actual, the plan, the rechecks a
/// review asks for, a verdict in words. No JSON, no wrapper card beyond what `ExpectedAndActual` draws.
struct StepAnswerView: View {
    let answer: StepAnswer

    /// A pane of a check's result is cut at this many lines.
    static let resultLines = 12

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s3) {
            if let result = answer.result, result.expected != nil || result.actual != nil {
                ExpectedAndActual(expected: result.expected, actual: result.actual, lineLimit: Self.resultLines)
            }
            if let plan = answer.plan { PlanView(plan: plan) }
            ForEach(Array(answer.rechecks.enumerated()), id: \.offset) { _, recheck in
                RecheckView(recheck: recheck)
            }
            if let verdict = answer.verdictSummary { paragraph(verdict) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, DesignTokens.Space.s2)
    }

    private func paragraph(_ text: String) -> some View {
        Text(text)
            .textStyle(.readingCompact)
            .foregroundStyle(DesignTokens.TextColor.primary.color)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }

    /// A short heading over a list: "Checks", "Not checked", "Expect".
    static func heading(_ text: String) -> some View {
        Text(text)
            .font(DesignTokens.TypeStyle.label.font)
            .foregroundStyle(DesignTokens.TextColor.secondary.color)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The plan: its summary as a paragraph, then what it checks and what it does not, each list only when it has items.
private struct PlanView: View {
    let plan: StepAnswer.Plan

    static let checksHeading = "Checks"
    static let skipsHeading = "Not checked"

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s3) {
            if let summary = plan.summary {
                Text(summary)
                    .textStyle(.readingCompact)
                    .foregroundStyle(DesignTokens.TextColor.primary.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            if !plan.checks.isEmpty {
                list(Self.checksHeading) {
                    ForEach(Array(plan.checks.enumerated()), id: \.offset) { _, check in
                        row(check.title, check.expect)
                    }
                }
            }
            if !plan.skips.isEmpty {
                list(Self.skipsHeading) {
                    ForEach(Array(plan.skips.enumerated()), id: \.offset) { _, skip in
                        row(skip.title, skip.why)
                    }
                }
            }
        }
    }

    private func list<Rows: View>(_ heading: String, @ViewBuilder rows: () -> Rows) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s1) {
            StepAnswerView.heading(heading)
            rows()
        }
        .accessibilityElement(children: .contain)
    }

    private func row(_ title: String, _ detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(DesignTokens.TypeStyle.body.font.weight(.medium))
                .foregroundStyle(DesignTokens.TextColor.primary.color)
                .fixedSize(horizontal: false, vertical: true)
            if let detail {
                Text(detail)
                    .font(DesignTokens.TypeStyle.secondary.font)
                    .foregroundStyle(DesignTokens.TextColor.secondary.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// One check the review asks to run again: its title, what to do as a numbered list, then what to expect.
private struct RecheckView: View {
    let recheck: StepAnswer.Recheck

    static let expectHeading = "Expect"

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
            Text(recheck.title)
                .font(DesignTokens.TypeStyle.rowTitle.font)
                .foregroundStyle(DesignTokens.TextColor.primary.color)
                .fixedSize(horizontal: false, vertical: true)
            if !recheck.instructions.isEmpty {
                VStack(alignment: .leading, spacing: DesignTokens.Space.s1) {
                    ForEach(Array(recheck.instructions.enumerated()), id: \.offset) { index, instruction in
                        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.s2) {
                            Text("\(index + 1).")
                                .font(DesignTokens.TypeStyle.body.font)
                                .monospacedDigit()
                                .foregroundStyle(DesignTokens.TextColor.tertiary.color)
                                .frame(minWidth: 18, alignment: .trailing)
                            Text(instruction)
                                .font(DesignTokens.TypeStyle.body.font)
                                .foregroundStyle(DesignTokens.TextColor.primary.color)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
            }
            if let expect = recheck.expect {
                VStack(alignment: .leading, spacing: DesignTokens.Space.s1) {
                    StepAnswerView.heading(Self.expectHeading)
                    Text(expect)
                        .font(DesignTokens.TypeStyle.body.font)
                        .foregroundStyle(DesignTokens.TextColor.primary.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
