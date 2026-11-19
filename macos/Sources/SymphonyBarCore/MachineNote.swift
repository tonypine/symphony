import Foundation

/// The notes Symphony wrote for a run's steps before the steps carried their answers: the one place that knows their
/// words. A note is one only when its text begins with a shape below exactly; anything else, however like, is somebody's.
public enum MachineNote {
    /// Whether `text`, a note under a run of kind `runKind`, is one of the machine-written shapes:
    /// - in any run, "The <step> step answered: " followed by a JSON object or list;
    /// - in a QA run, a check's "<step>: <status>. Expected: …", a review's "The QA review asked for a recheck of …" and
    ///   a step that "gave no answer Symphony takes".
    public static func isMachineWritten(_ text: String, runKind: String?) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.range(of: #"^The [^\n]+ step answered: [\{\[]"#, options: .regularExpression) != nil { return true }
        guard runKind == "qa" else { return false }
        if text.hasPrefix("The QA review asked for a recheck of") { return true }
        let firstLine = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? text
        if firstLine.range(of: #"^The .+ step of the QA pass gave no answer Symphony takes"#, options: .regularExpression) != nil { return true }
        return text.range(of: #"^[^\n]+: [A-Za-z][A-Za-z ]*\. Expected:"#, options: .regularExpression) != nil
    }
}
