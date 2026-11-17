import SwiftUI
import SymphonyBarCore

// The catalog's Key-value list (`docs/design/catalog/stories.js`, `kv()`; `.kv` and `.kv-group` in `components.css`,
// TP-1511): facts about one thing as label and value pairs. The labels are in the secondary colour, in a column as wide
// as the longest; the values beside them are any view: words, a badge, chips, a path with its copy button. Stacked, for
// a place narrower than 300 pt, each label sits above its value in the label style. A fact that is unknown is left out,
// never drawn as a dash. Every measure is `DesignTokens.KeyValue`'s.

private struct KeyValueLayoutKey: EnvironmentKey {
    static let defaultValue = DesignTokens.KeyValue.Layout.columns
}

private struct KeyValueStyleKey: EnvironmentKey {
    static let defaultValue = DesignTokens.TypeStyle.body
}

extension EnvironmentValues {
    /// How the list around a `KeyValueRow` lays its facts out.
    fileprivate var keyValueLayout: DesignTokens.KeyValue.Layout {
        get { self[KeyValueLayoutKey.self] }
        set { self[KeyValueLayoutKey.self] = newValue }
    }

    /// The list's text style, for its labels.
    fileprivate var keyValueStyle: DesignTokens.TypeStyle {
        get { self[KeyValueStyleKey.self] }
        set { self[KeyValueStyleKey.self] = newValue }
    }
}

/// The catalog's Key-value list: its `KeyValueRow`s in two columns, or stacked. `heading` names a group of them in
/// small capitals (the catalog's Grouped story); put groups one under the other with `KeyValueGroups`.
public struct KeyValueList<Content: View>: View {
    let layout: DesignTokens.KeyValue.Layout
    let style: DesignTokens.TypeStyle
    let rowGap: Double
    let heading: String?
    @ViewBuilder let content: Content

    /// `style` is the words' style, `body` as the catalog's `.kv`; the Tickets details' list is `secondary` with
    /// `DesignTokens.KeyValue.compactRowGap` between its facts.
    public init(
        layout: DesignTokens.KeyValue.Layout = .columns, style: DesignTokens.TypeStyle = .body,
        rowGap: Double = DesignTokens.KeyValue.rowGap, heading: String? = nil, @ViewBuilder content: () -> Content
    ) {
        self.layout = layout
        self.style = style
        self.rowGap = rowGap
        self.heading = heading
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.KeyValue.groupHeadingGap) {
            if let heading {
                Text(heading.uppercased())
                    .tracking(CGFloat(DesignTokens.KeyValue.groupHeadingTracking * DesignTokens.TypeStyle.caption.size))
                    .textStyle(.caption)
                    .foregroundStyle(DesignTokens.TextColor.secondary.color)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityLabel(heading)
            }
            Grid(
                alignment: .topLeading,
                horizontalSpacing: DesignTokens.KeyValue.columnGap,
                verticalSpacing: layout == .stacked ? DesignTokens.KeyValue.stackedValueGap : rowGap
            ) {
                content
            }
            .environment(\.keyValueLayout, layout)
            .environment(\.keyValueStyle, style)
        }
        .textStyle(style)
        .foregroundStyle(DesignTokens.TextColor.primary.color)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}

/// Groups of facts one under the other, `DesignTokens.KeyValue.groupGap` apart: each a `KeyValueList` with a heading.
public struct KeyValueGroups<Content: View>: View {
    @ViewBuilder let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.KeyValue.groupGap) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One fact of a `KeyValueList`: its label, then its value, any view. VoiceOver reads it as a group named by the label,
/// its value inside, so a button or a link in the value stays its own.
public struct KeyValueRow<Value: View>: View {
    let label: String
    let value: Value
    /// An unknown fact: the row draws nothing.
    var leftOut = false
    @Environment(\.keyValueLayout) private var layout
    @Environment(\.keyValueStyle) private var style

    public init(_ label: String, @ViewBuilder value: () -> Value) {
        self.label = label
        self.value = value()
    }

    public var body: some View {
        if !leftOut { row }
    }

    @ViewBuilder private var row: some View {
        switch layout {
        case .columns:
            GridRow(alignment: .firstTextBaseline) {
                labelText
                    .textStyle(style)
                    .gridColumnAlignment(.leading)
                valueView
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(label)
        case .stacked:
            GridRow {
                VStack(alignment: .leading, spacing: DesignTokens.KeyValue.stackedLabelGap) {
                    labelText.textStyle(.label)
                    valueView
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(label)
        }
    }

    private var labelText: some View {
        Text(label)
            .foregroundStyle(DesignTokens.TextColor.secondary.color)
            .fixedSize()
    }

    private var valueView: some View {
        value
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension KeyValueRow where Value == KeyValueText {
    /// A fact in words; left out (nothing drawn) when `text` is nil or empty: an unknown fact is never a dash.
    public init(_ label: String, text: String?) {
        self.label = label
        self.value = KeyValueText(text ?? "")
        self.leftOut = text?.isEmpty ?? true
    }
}

/// A value in words, selectable.
public struct KeyValueText: View {
    let text: String

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        Text(text).textSelection(.enabled)
    }
}

/// A value that is a path: in the monospaced style, selectable, with a quiet Copy button beside it that says Copied
/// once it put the path on the pasteboard.
public struct KeyValuePath: View {
    public static let copyTitle = "Copy"
    public static let copiedTitle = "Copied"

    let path: String
    let copyLabel: String
    let copy: (String) -> Void
    @State private var copied: Bool

    /// `copyLabel` is what VoiceOver reads for the button ("Copy the workspace path"); `copied` draws it as after a
    /// click.
    public init(_ path: String, copyLabel: String = "Copy the path", copied: Bool = false, copy: @escaping (String) -> Void) {
        self.path = path
        self.copyLabel = copyLabel
        self.copy = copy
        _copied = State(initialValue: copied)
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.KeyValue.valueGap) {
            Text(path)
                .textStyle(.mono)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 0)
            Button(copied ? Self.copiedTitle : Self.copyTitle) {
                copy(path)
                copied = true
            }
            .directorButton(.quiet, size: .small)
            .accessibilityLabel(copyLabel)
        }
    }
}
