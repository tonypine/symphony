import Foundation

/// SU11, the Add Repo sheet's last step: once the repo is saved and Symphony has read it, the same setup checks as the
/// Setup page, for that repo and the global setup. Errors keep Done off until they are fixed; warnings don't. Kept
/// free of SwiftUI so what Done allows is unit tested.
public struct AddRepoSetupCheck: Equatable {
    public enum Phase: Equatable {
        /// Symphony is reading the repo and checking it.
        case checking
        /// Symphony's answer: the repo's problems and the global ones.
        case checked(SetupPayload)
        /// Symphony didn't answer in time, or couldn't check.
        case failed(String)
        /// Symphony isn't running: it checks the repo when it starts.
        case onNextStart
    }

    public static let doneTitle = "Done"
    public static let startTitle = "Start Symphony"
    public static let checkAgainTitle = SetupPage.checkAgainTitle
    /// Done's help, and the line beside it, while the repo has an error.
    public static let doneBlocked = "Done is available once there are no errors."

    public var key: String
    /// The route Connect wrote.
    public var route: RepositoryRoute
    public var phase: Phase

    public init(key: String, route: RepositoryRoute, phase: Phase) {
        self.key = key
        self.route = route
        self.phase = phase
    }

    /// The step right after Connect: checking, or waiting for Symphony to start.
    public init(key: String, route: RepositoryRoute, apply: AddRepoApply) {
        self.init(key: key, route: route, phase: apply == .onNextStart ? .onNextStart : .checking)
    }

    /// The problems listed, nil until Symphony has answered.
    public var payload: SetupPayload? {
        if case let .checked(payload) = phase { return payload }
        return nil
    }

    /// Done is off while Symphony checks, while it couldn't, and while the repo or the global setup has an error. A
    /// warning doesn't stop it, and neither does a Symphony that isn't running: it checks at start.
    public var canFinish: Bool {
        switch phase {
        case .checking, .failed: false
        case let .checked(payload): payload.errors.isEmpty
        case .onNextStart: true
        }
    }

    /// Why Done is off, shown beside it and as its help; nil while it is on.
    public var doneProblem: String? {
        switch phase {
        case .checking: "Done is available once Symphony has checked \(key)."
        case .failed: "Done is available once Symphony has checked \(key). Check again, or close: \(key) stays saved."
        case let .checked(payload): payload.errors.isEmpty ? nil : Self.doneBlocked
        case .onNextStart: nil
        }
    }

    /// The step's sentence.
    public var headline: String {
        switch phase {
        case .checking:
            return "Checking setup for \(key)…"
        case .failed:
            return "Couldn't check setup for \(key)."
        case .onNextStart:
            return "Symphony isn't running, so it checks \(key) when it starts."
        case let .checked(payload):
            let errors = payload.errors.count
            let warnings = payload.warnings.count
            if errors == 0 && warnings == 0 { return "\(key) is set up right." }
            return "Setup has " + SetupPage.sentenceCounts(errors: errors, warnings: warnings) + " for \(key)."
        }
    }

    /// The line under the sentence, nil when there is nothing more to say.
    public var detail: String? {
        switch phase {
        case .checking:
            return "Symphony reads \(key) from symphony.yml, then runs the same checks as the Setup page."
        case let .failed(message):
            return message
        case .onNextStart:
            return "If something is wrong then, the Setup page opens. Start Symphony now, or later from the menu bar."
        case let .checked(payload):
            if !payload.errors.isEmpty {
                return "Fix each error here, or close the sheet: \(key) stays saved and its errors stay on the Setup page."
            }
            if !payload.warnings.isEmpty { return "Warnings don't stop \(key) from taking tickets." }
            return nil
        }
    }

    /// The Errors and Warnings, grouped by category as on the Setup page; empty until Symphony answered.
    public func page(now: Date = Date()) -> SetupPage? {
        payload.map { SetupPage(payload: $0, now: now) }
    }

    /// Once the repo has no error, what Connect wrote: the project by its ID and the team, each a label and a value.
    public var written: [SetupPayload.Detail] {
        guard let payload, payload.errors.isEmpty else { return [] }
        var lines = (route.projects ?? []).map { SetupPayload.Detail(label: "Project", value: $0) }
        lines.append(SetupPayload.Detail(label: "Team", value: route.team ?? "Not set: the project isn't in exactly one team"))
        if let labels = route.labels, !labels.isEmpty {
            lines.append(SetupPayload.Detail(label: labels.count == 1 ? "Label" : "Labels", value: labels.joined(separator: ", ")))
        }
        return lines
    }

    /// Start Symphony shows only while Symphony isn't running.
    public var offersStart: Bool { phase == .onNextStart }

    /// Check Again shows once Symphony answered, or failed to.
    public var offersCheckAgain: Bool {
        switch phase {
        case .checked, .failed: true
        case .checking, .onNextStart: false
        }
    }
}
