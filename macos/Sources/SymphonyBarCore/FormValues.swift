/// The values of a form edited whole, one per setting, so a page can count how many settings differ from what it read
/// (TP-1576): the Settings page's Save bar shows that count. A value that is a struct counts each of its stored values
/// on its own, all the way down, so three edits inside one settings struct are three changes; a list, a dictionary, an
/// optional, an enum or a plain value is one setting. An edit put back by hand differs from nothing, so it counts as
/// none.
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
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .struct, !mirror.children.isEmpty {
            for (offset, child) in mirror.children.enumerated() {
                flatten(child.value, at: "\(path).\(child.label ?? String(offset))", into: &values)
            }
        } else {
            values[path] = Value(value: value)
        }
    }
}

private extension Equatable {
    /// Whether `other` is a value of this type equal to this one.
    func isEqual(to other: Any) -> Bool {
        (other as? Self) == self
    }
}
