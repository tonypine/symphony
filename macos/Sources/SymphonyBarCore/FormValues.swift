/// The values of a form edited whole, one per setting, so a page can count how many settings differ from what it read
/// (TP-1576): the Settings page's Save bar shows that count. A value that is a struct counts each of its stored values
/// on its own, all the way down, so three edits inside one settings struct are three changes. A dictionary counts each
/// key's value on its own (two report triggers, two risk rules, the step lists of two phases), and a set each member
/// it holds or lacks (two ticket priorities turned on are two changes). A list, an optional, an enum or a plain value
/// is one setting, and so is a value that is a `FormSetting`; a `FormFieldGroup` names its own parts. An edit put back
/// by hand differs from nothing, so it counts as none.
public struct FormValues: Equatable {
    /// One setting's value: compared with `==` when its type is equatable, by its description when not.
    struct Value: Equatable {
        let value: Any

        static func == (lhs: Value, rhs: Value) -> Bool {
            if let equatable = lhs.value as? any Equatable { return equatable.isEqual(to: rhs.value) }
            return String(reflecting: lhs.value) == String(reflecting: rhs.value)
        }
    }

    /// Each setting's value, by its path (`settings.stopTimeoutSeconds`).
    private(set) var values: [String: Value]

    /// The form's values, each under its name.
    public init(_ fields: [(String, Any)]) {
        values = [:]
        for (name, value) in fields { Self.flatten(value, at: name, into: &values) }
    }

    /// How many settings differ between `self`, the values read, and `current`; a setting only one side holds
    /// counts as changed.
    public func changes(to current: FormValues) -> Int {
        Set(values.keys).union(current.values.keys).filter { values[$0] != current.values[$0] }.count
    }

    /// Takes the settings `other` holds in place of these, keeping the rest: the values a later read filled in.
    public mutating func take(_ other: FormValues) {
        values.merge(other.values) { _, new in new }
    }

    private static func flatten(_ value: Any, at path: String, into values: inout [String: Value]) {
        if value is FormSetting {
            values[path] = Value(value: value)
            return
        }
        if let group = value as? FormFieldGroup {
            for (name, part) in group.formFields { flatten(part, at: "\(path).\(name)", into: &values) }
            return
        }
        let mirror = Mirror(reflecting: value)
        switch mirror.displayStyle {
        case .struct where !mirror.children.isEmpty:
            for (offset, child) in mirror.children.enumerated() {
                flatten(child.value, at: "\(path).\(child.label ?? String(offset))", into: &values)
            }
        case .dictionary:
            for entry in mirror.children {
                let pair = Array(Mirror(reflecting: entry.value).children)
                flatten(pair[1].value, at: "\(path)[\(String(reflecting: pair[0].value))]", into: &values)
            }
        case .set:
            // A member counts by being there: one the other side lacks is a setting only one side holds.
            for member in mirror.children { values["\(path){\(String(reflecting: member.value))}"] = Value(value: true) }
        default:
            values[path] = Value(value: value)
        }
    }
}

/// A value the Save bar counts as one setting whatever its shape: a step list is one setting, though it holds its
/// steps and whether it is still Symphony's default.
public protocol FormSetting {}

extension PhaseSteps: FormSetting {}

extension PhaseSettings: FormFieldGroup {
    /// Each run kind's list, whether QA passes are stepped, and each QA playbook's list as the editor shows it: a
    /// playbook the file doesn't set is its default, as `==` reads it, so opening one in the editor is no change.
    public var formFields: [(String, Any)] {
        let playbooks = Dictionary(uniqueKeysWithValues: qaPlaybookKinds.map { ($0, self[.qaPlaybook($0)]) })
        return [("lists", lists), ("qaStepped", qaStepped), ("qaPlaybooks", playbooks)]
    }
}

/// A value that names the parts the Save bar counts, when its stored values aren't them: a value with its own `==`.
public protocol FormFieldGroup {
    /// The parts, each under its name.
    var formFields: [(String, Any)] { get }
}

private extension Equatable {
    /// Whether `other` is a value of this type equal to this one.
    func isEqual(to other: Any) -> Bool {
        (other as? Self) == self
    }
}
