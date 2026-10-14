import AppKit
import SwiftUI

/// A token field of Linear labels that completes from `suggestions` and takes only those: a label the project's
/// issues can't carry would never match one.
struct LabelTokenField: NSViewRepresentable {
    @Binding var labels: [String]
    let suggestions: [String]
    let placeholder: String

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSTokenField {
        let field = NSTokenField()
        field.delegate = context.coordinator
        field.tokenStyle = .rounded
        field.completionDelay = 0
        field.lineBreakMode = .byWordWrapping
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.objectValue = labels
        return field
    }

    func updateNSView(_ field: NSTokenField, context: Context) {
        context.coordinator.parent = self
        field.placeholderString = placeholder
        field.isEnabled = context.environment.isEnabled
        // While it is typed in, the field holds the truth; it reads the labels again once it isn't.
        if field.currentEditor() == nil, (field.objectValue as? [String]) ?? [] != labels {
            field.objectValue = labels
        }
    }

    final class Coordinator: NSObject, NSTokenFieldDelegate {
        var parent: LabelTokenField

        init(_ parent: LabelTokenField) {
            self.parent = parent
        }

        func tokenField(
            _ tokenField: NSTokenField,
            completionsForSubstring substring: String,
            indexOfToken tokenIndex: Int,
            indexOfSelectedItem selectedIndex: UnsafeMutablePointer<Int>?
        ) -> [Any]? {
            let picked = Set(parent.labels)
            return parent.suggestions.filter {
                !picked.contains($0) && (substring.isEmpty || $0.localizedCaseInsensitiveContains(substring))
            }
        }

        func tokenField(_ tokenField: NSTokenField, shouldAdd tokens: [Any], at index: Int) -> [Any] {
            let added = tokens.compactMap { token in
                (token as? String).flatMap(known)
            }
            DispatchQueue.main.async { self.read(tokenField) }
            return added
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTokenField else { return }
            read(field)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTokenField else { return }
            read(field)
            // Drops the text that never became a label.
            field.objectValue = parent.labels
        }

        /// The label of `suggestions` that `text` names, matched without case.
        private func known(_ text: String) -> String? {
            let text = text.trimmingCharacters(in: .whitespaces)
            return parent.suggestions.first { $0.caseInsensitiveCompare(text) == .orderedSame }
        }

        private func read(_ field: NSTokenField) {
            var labels: [String] = []
            for token in (field.objectValue as? [Any]) ?? [] {
                if let label = (token as? String).flatMap(known), !labels.contains(label) { labels.append(label) }
            }
            if labels != parent.labels { parent.labels = labels }
        }
    }
}
