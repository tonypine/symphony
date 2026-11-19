import SwiftUI
import SymphonyBarCore
import SymphonyBarUI

// The blocks of a Conductor message: each of the four new components alone, in its variations, and each block type inside
// a message as the bench draws it (`Tests/Fixtures/timeline/conductor-blocks.json`, one message a block type).

/// The Conductor's messages, one a block type, on one page.
let timelineModelConductorBlocks: TimelineModel = {
    guard let events = try? Data(contentsOf: timelineFixtures.appendingPathComponent("conductor-blocks.json")),
          let history = TicketEventsPayload.decode(events)
    else { fatalError("The Conductor's blocks fixture is missing from \(timelineFixtures.path)") }
    return TimelineModel.build(history, reference: timelineReference, calendar: timelineCalendar)
}()

/// The page with the message `id` alone.
func conductorBlockModel(_ id: String) -> TimelineModel {
    var model = timelineModelConductorBlocks
    for day in model.days.indices { model.days[day].items = model.days[day].items.filter { $0.id == "entry-\(id)" } }
    model.days.removeAll { $0.items.isEmpty }
    return model
}

/// The blocks of message `id` in the fixture.
func conductorBlocks(_ id: String) -> [ConductorBlock] {
    for item in timelineModelConductorBlocks.items {
        if case let .entry(entry) = item, entry.id == id { return entry.conductor?.blocks ?? [] }
    }
    return []
}

/// The Question the ticket page fixture's TP-1245 waits on, which the Question block of a message asks.
@MainActor
var conductorQuestionContext: ConductorQuestionContext {
    ConductorQuestionContext(questions: TicketPage.questions(of: "TP-1245", in: ticketPageInbox.items), narrow: true)
}

/// The tickets and pull requests the Inbox fixture resolves: a reference in a message is a chip with their state.
let conductorReferences: [String: Reference] = (InboxPayload.decode((try? Data(contentsOf: fixture)) ?? Data())?.items ?? [])
    .reduce(into: [:]) { $0.merge($1.references) { kept, _ in kept } }

/// A message with its blocks, as the timeline draws it.
@MainActor
func conductorBlockMessage(_ id: String) -> AnyView {
    AnyView(
        TimelineSection(
            model: conductorBlockModel(id), transcripts: StepTranscripts { _ in .unreachable }, calendar: timelineCalendar
        )
        .padding(DesignTokens.Space.s5)
        .frame(width: 780, alignment: .leading)
        .background(DesignTokens.Surface.content.color)
            .environment(\.conductorQuestions, conductorQuestionContext)
            .environment(\.mentionReferences, conductorReferences)
            .environment(\.artifactImages, ticketPageImages())
    )
}

/// A component alone, on the content surface at the width a message gives a block.
@MainActor
func conductorBlockAlone<Content: View>(width: CGFloat = ConductorBlocksView.maxWidth, @ViewBuilder _ content: () -> Content) -> AnyView {
    AnyView(
        content()
            .frame(width: width, alignment: .leading)
            .padding(DesignTokens.Space.s5)
            .background(DesignTokens.Surface.content.color)
            .environment(\.artifactImages, ticketPageImages())
    )
}

private func path(_ stops: String, loops: Int = 0, elapsed: Int? = nil) -> ConductorBlock.Path {
    let json = #"[{"type":"path","stops":\#(stops),"loops":\#(loops)\#(elapsed.map { #","elapsed_ms":\#($0)"# } ?? "")}]"#
    guard case let .path(path)? = ConductorBlock.read(json: json).first else { fatalError("The run path variation does not read") }
    return path
}

private func stop(_ phase: String, _ state: String, times: Int = 1, run: Int? = nil) -> String {
    #"{"phase":"\#(phase)","state":"\#(state)","times":\#(times)\#(run.map { #","run_number":\#($0)"# } ?? "")}"#
}

private func attempts(sameLine: Bool, lines: [String?]) -> ConductorBlock.Attempts {
    let tries = lines.enumerated().map { index, line in
        #"{"at":"2026-10-08T09:0\#(2 + index):30Z","outcome":"failed","duration_ms":15000\#(line.map { #","line":"\#($0)""# } ?? "")}"#
    }.joined(separator: ",")
    let json = #"[{"type":"attempts","step_id":"build","title":"Build","same_line":\#(sameLine),"tries":[\#(tries)]}]"#
    guard case let .attempts(attempts)? = ConductorBlock.read(json: json).first else { fatalError("The attempts variation does not read") }
    return attempts
}

private func findings(_ items: [(String, Bool)]) -> ConductorBlock.Findings {
    let list = items.enumerated().map { index, item in
        #"{"id":"f\#(index)","title":"\#(item.0)","state":"\#(item.1 ? "resolved" : "open")"}"#
    }.joined(separator: ",")
    guard case let .findings(findings)? = ConductorBlock.read(json: #"[{"type":"findings","items":[\#(list)]}]"#).first else {
        fatalError("The ledger variation does not read")
    }
    return findings
}

private func compare(_ json: String) -> ConductorBlock.Compare {
    guard case let .compare(compare)? = ConductorBlock.read(json: "[\(json)]").first else { fatalError("The compare variation does not read") }
    return compare
}

private let shotID = "1a5944804739c3246135942da82f849565310c15e861390baa8bd75677fa48b0"

/// The Lifecycle section of the mid-way ticket with the Conductor's 600K tokens: its own segment in the accent, and its
/// legend entry.
@MainActor
func lifecycleWithConductor() -> AnyView {
    var lifecycle = lifecycleRead("mid-way").lifecycle!
    lifecycle.tokens.total += 600_000
    return AnyView(
        LifecycleSection(model: LifecycleModel.build(lifecycle, path: lifecycleRead("mid-way").phasePath, conductorTokens: 600_000))
            .padding(DesignTokens.Space.s5)
            .frame(width: 780 + 2 * DesignTokens.Space.s5, alignment: .leading)
            .background(DesignTokens.Surface.window.color)
    )
}

/// Every variation of the four components and the message each block sits in, light or dark.
@MainActor
func conductorBlockRenders(_ scheme: ColorScheme, suffix: String) {
    // Run path: nothing folded, both ends folded, a failed stop among the earlier ones, narrow (names cut), the first
    // and the last stop.
    let short = [stop("Coding", "done"), stop("QA", "current", run: 1), stop("Merge", "upcoming")]
    render(conductorBlockAlone { RunPath(path: path("[\(short.joined(separator: ","))]")) }, scheme, to: "run-path-nothing-folded-\(suffix).png")
    let long = [
        stop("Backlog", "done"), stop("Todo", "done"), stop("Coding", "done"), stop("QA", "failed", times: 2), stop("Rework", "current", run: 2),
        stop("QA", "upcoming"), stop("Merge", "upcoming"),
    ]
    render(conductorBlockAlone { RunPath(path: path("[\(long.joined(separator: ","))]", loops: 1, elapsed: 11_520_000)) }, scheme, to: "run-path-both-ends-folded-\(suffix).png")
    let failedEarlier = [
        stop("Coding", "done"), stop("QA", "failed"), stop("Rework", "done"), stop("QA", "failed"), stop("Rework", "done"), stop("QA", "current"),
        stop("Merge", "upcoming"),
    ]
    render(conductorBlockAlone { RunPath(path: path("[\(failedEarlier.joined(separator: ","))]", loops: 2, elapsed: 20_400_000)) }, scheme, to: "run-path-failed-earlier-\(suffix).png")
    render(conductorBlockAlone(width: 300) { RunPath(path: path("[\(long.joined(separator: ","))]", loops: 1, elapsed: 11_520_000)) }, scheme, to: "run-path-narrow-\(suffix).png")
    let start = [stop("Coding", "current", run: 1), stop("QA", "upcoming"), stop("Merge", "upcoming")]
    render(conductorBlockAlone { RunPath(path: path("[\(start.joined(separator: ","))]")) }, scheme, to: "run-path-at-the-start-\(suffix).png")

    // Attempts: with and without the same line every time, and a try with no line.
    let build = "InitiativesView.swift:443: reference to member 'status' cannot be resolved"
    render(conductorBlockAlone { AttemptsList(attempts: attempts(sameLine: true, lines: [build, build])) }, scheme, to: "attempts-same-error-\(suffix).png")
    render(conductorBlockAlone { AttemptsList(attempts: attempts(sameLine: false, lines: [build, "StoryRow.swift:31: cannot find 'trail' in scope", nil])) }, scheme, to: "attempts-different-errors-\(suffix).png")

    // Expected and actual: text and text, screenshot and screenshot, and narrow (stacked).
    let texts = compare(#"{"type":"compare","expected":{"text":"Checkout total rounding: Needs a fix"},"actual":{"text":"Checkout total rounding: Next in line"}}"#)
    render(conductorBlockAlone { ExpectedAndActual(compare: texts) }, scheme, to: "expected-and-actual-text-\(suffix).png")
    let shots = compare(#"{"type":"compare","expected":{"artifact_id":"\#(shotID)"},"actual":{"artifact_id":"\#(shotID)"}}"#)
    render(conductorBlockAlone { ExpectedAndActual(compare: shots) }, scheme, to: "expected-and-actual-screenshots-\(suffix).png")
    render(conductorBlockAlone(width: 340) { ExpectedAndActual(compare: texts) }, scheme, to: "expected-and-actual-narrow-\(suffix).png")

    // Findings ledger: all resolved, and mixed.
    let done = findings([("Needs-a-fix row reads Next in line", true), ("Duplicate of the row finding", true)])
    render(conductorBlockAlone { FindingsLedger(findings: done) }, scheme, to: "findings-ledger-all-resolved-\(suffix).png")
    let mixed = findings([("Needs-a-fix row reads Next in line", false), ("Duplicate of the row finding", true), ("Strip legend counts the wrong ticket", true)])
    render(conductorBlockAlone { FindingsLedger(findings: mixed) }, scheme, to: "findings-ledger-mixed-\(suffix).png")

    qaStepRenders(scheme, suffix: suffix)
    stepAnswerRenders(scheme, suffix: suffix)
    render(lifecycleWithConductor(), scheme, to: "lifecycle-conductor-segment-\(suffix).png")

    // Each block inside a message.
    for (index, name) in [
        "steps", "evidence", "budget", "question", "reference", "epic", "path", "attempts", "compare", "compare-screenshots", "findings",
    ].enumerated() {
        render(conductorBlockMessage("b\(index + 1)"), scheme, to: "conductor-blocks-\(name)-\(suffix).png")
    }
}

// MARK: - A stepped QA pass

/// A QA run whose steps carry their answers (`Tests/Fixtures/timeline/qa-steps.json`): a plan, two checks with results, a
/// review asking for two rechecks and a verdict.
let qaStepsRun: RunGroupModel = {
    guard let events = try? Data(contentsOf: timelineFixtures.appendingPathComponent("qa-steps.json")),
          let history = TicketEventsPayload.decode(events),
          let run = TimelineModel.build(history, reference: timelineReference, calendar: timelineCalendar).run("qa-1")
    else { fatalError("The QA steps fixture is missing from \(timelineFixtures.path)") }
    return run
}()

/// The QA run with the step `stepID` unfolded.
@MainActor
func qaRunGroup(unfolding stepID: String) -> AnyView {
    AnyView(
        RunGroup(run: qaStepsRun, transcripts: StepTranscripts { _ in .unreachable }, unfolded: true, unfoldedSteps: [stepID])
            .padding(DesignTokens.Space.s5)
            .frame(width: 760)
            .background(DesignTokens.Surface.content.color)
    )
}

@MainActor
func qaStepRenders(_ scheme: ColorScheme, suffix: String) {
    render(qaRunGroup(unfolding: "check-1"), scheme, to: "run-group-qa-check-result-\(suffix).png")
    render(qaRunGroup(unfolding: "plan"), scheme, to: "run-group-qa-plan-\(suffix).png")
    render(qaRunGroup(unfolding: "review"), scheme, to: "run-group-qa-recheck-\(suffix).png")
}

/// An implementation run (`Tests/Fixtures/timeline/step-answers.json`) whose first step answered in three entries, one of
/// several lines, and whose Tests step failed with a long reason.
let stepAnswersRun: RunGroupModel = {
    guard let events = try? Data(contentsOf: timelineFixtures.appendingPathComponent("step-answers.json")),
          let history = TicketEventsPayload.decode(events),
          let run = TimelineModel.build(history, reference: timelineReference, calendar: timelineCalendar).run("impl-1")
    else { fatalError("The step answers fixture is missing from \(timelineFixtures.path)") }
    return run
}()

@MainActor
func stepAnswersRunGroup(unfolding stepID: String) -> AnyView {
    AnyView(
        RunGroup(run: stepAnswersRun, transcripts: StepTranscripts { _ in .unreachable }, unfolded: true, unfoldedSteps: [stepID])
            .padding(DesignTokens.Space.s5)
            .frame(width: 760)
            .background(DesignTokens.Surface.content.color)
    )
}

@MainActor
func stepAnswerRenders(_ scheme: ColorScheme, suffix: String) {
    render(stepAnswersRunGroup(unfolding: "code"), scheme, to: "run-group-step-answer-\(suffix).png")
    render(stepAnswersRunGroup(unfolding: "tests"), scheme, to: "run-group-failed-step-long-reason-\(suffix).png")
}
