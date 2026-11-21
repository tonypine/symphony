import Foundation

// The Settings page of the Symphony window (TP-1575): the form's blocks, grouped into a short list of sections the
// page's own section list shows down its side. A section shows its blocks alone, in this order.

/// One block of the Settings form, as the old Settings window drew it: a grouped section with its own header.
public enum SettingsBlock: String, CaseIterable, Equatable, Hashable {
    case symphony, notifications, developmentMode, updates, agents, tickets, boardStates, codeReview, riskRules,
         phases, timeouts, gitHubUpdates, linearWebhooks, dispatchLoops, dispatch, ledger, reports, conductor,
         macAppQA, environment

    /// The block's header, as the form names it and its error lines point at it ("see Timeouts").
    public var title: String {
        switch self {
        case .symphony: "Symphony"
        case .notifications: "Notifications"
        case .developmentMode: "Development mode"
        case .updates: "Updates"
        case .agents: "Agents"
        case .tickets: "Tickets"
        case .boardStates: "Board states"
        case .codeReview: "Code Review"
        case .riskRules: "Code Review risk rules"
        case .phases: "Phases"
        case .timeouts: "Timeouts"
        case .gitHubUpdates: "GitHub updates"
        case .linearWebhooks: "Linear webhooks"
        case .dispatchLoops: "Dispatch loops"
        case .dispatch: "Dispatch"
        case .ledger: "Ledger"
        case .reports: "Reports"
        case .conductor: "Conductor"
        case .macAppQA: "macOS app QA"
        case .environment: "Environment"
        }
    }

    /// The section that shows it.
    public var section: SettingsSection {
        SettingsSection.allCases.first { $0.blocks.contains(self) }!
    }

    /// Where an error line sends the person: the block, and the section that holds it when its name differs.
    /// "Timeouts, under Agents".
    public var pointer: String {
        section.title == title ? title : "\(title), under \(section.title)"
    }
}

/// One section of the Settings page's section list.
public enum SettingsSection: String, CaseIterable, Equatable, Hashable, Identifiable {
    case symphony, notifications, updates, agents, tickets, connections, review, records, environment

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .symphony: "Symphony"
        case .notifications: "Notifications"
        case .updates: "Updates"
        case .agents: "Agents"
        case .tickets: "Tickets"
        case .connections: "GitHub and Linear"
        case .review: "Review and QA"
        case .records: "Records"
        case .environment: "Environment"
        }
    }

    public var symbol: String {
        switch self {
        case .symphony: "gearshape"
        case .notifications: "bell"
        case .updates: "arrow.down.circle"
        case .agents: "gauge.with.dots.needle.33percent"
        case .tickets: "ticket"
        case .connections: "antenna.radiowaves.left.and.right"
        case .review: "checkmark.seal"
        case .records: "tray.full"
        case .environment: "key"
        }
    }

    /// Its blocks, in the order it shows them.
    public var blocks: [SettingsBlock] {
        switch self {
        case .symphony: [.symphony, .developmentMode]
        case .notifications: [.notifications]
        case .updates: [.updates]
        case .agents: [.agents, .timeouts, .conductor]
        case .tickets: [.tickets, .boardStates, .dispatch, .dispatchLoops]
        case .connections: [.gitHubUpdates, .linearWebhooks]
        case .review: [.codeReview, .riskRules, .phases, .macAppQA]
        case .records: [.ledger, .reports]
        case .environment: [.environment]
        }
    }

    /// Where the page opens: its first section.
    public static let first: SettingsSection = .symphony

    /// How many of `failing` this section holds: the count its row in the section list shows, in the problem colour.
    public func failures(_ failing: Set<SettingsBlock>) -> Int {
        blocks.filter(failing.contains).count
    }
}

extension SettingsIssue {
    /// The block whose field the issue is about.
    public var block: SettingsBlock {
        switch self {
        case .configPathMissing, .configPathNotAbsolute, .configPathNotFile, .stopTimeoutOutOfRange, .restartTimeoutOutOfRange:
            .symphony
        case .checkoutPathMissing, .checkoutPathNotAbsolute, .checkoutPathNotDirectory, .commandPrefixUnbalancedQuotes,
             .embeddedSymphonyMissing:
            .developmentMode
        case .linearAPIKeyMissing, .environmentNameInvalid, .environmentNameDuplicate, .environmentNameReserved:
            .environment
        }
    }
}
