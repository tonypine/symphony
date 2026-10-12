import Foundation

/// `repositories[<key>].state_machine`, the version of the ticket state machine a repository runs, as
/// `docs/design/state-machine.md` describes it. Legacy is the default, so its choice removes the key.
public enum StateMachineChoice: String, CaseIterable, Identifiable {
    case legacy
    case designed

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .legacy: return "Legacy"
        case .designed: return "Designed"
        }
    }

    /// One line on which machine the choice runs.
    public var explanation: String {
        switch self {
        case .legacy:
            return "Today's machine: Auto Review, In Review and Human Review."
        case .designed:
            return "The redesigned machine: Code Review, QA and holds, as docs/design/state-machine.md describes."
        }
    }

    /// The choice for the value in the file: nil or an unknown value is Legacy, the default.
    public init(override: String?) {
        self = override.flatMap(StateMachineChoice.init(rawValue:)) ?? .legacy
    }

    /// The value written to `symphony.yml`; nil for Legacy, the default, removes the key.
    public var override: String? {
        self == .legacy ? nil : rawValue
    }
}

/// The state machine's control labels.
public enum StateMachine {
    public static let pickerTitle = "State machine"
}
