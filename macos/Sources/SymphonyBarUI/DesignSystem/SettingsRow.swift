import SwiftUI
import SymphonyBarCore

// A setting's row and the group that holds them (TP-1574): the catalog's `.toggle-row` made general, so a page of
// settings is built of one kind of row whatever its control (a switch, a number field, a time field, a pop-up, a text
// field). Every measure is `DesignTokens.SettingsRow`'s.

extension EnvironmentValues {
    /// The label of the `SettingsRow` a control sits in: what VoiceOver reads for a control given no label of its own.
    @Entry var settingsRowLabel: String? = nil
    /// Whether the `SettingsRow` a control sits in shows an error: the control draws its edge in the problem colour.
    @Entry var settingsRowInvalid = false
}

extension View {
    /// What VoiceOver reads for the design-system control inside (a switch, a number, time or text field), in place of
    /// its row's label: "Summary size limit in tokens" for the row Summary size limit.
    public func controlLabel(_ label: String) -> some View {
        environment(\.settingsRowLabel, label)
    }
}

/// One setting: its label over the one line under it, and its control at the trailing end, centred on them. The line
/// is the reason the setting is off when `disabledReason` is set (the control is off too, with the not-allowed pointer
/// and the reason as its help), else the error in the problem colour (the control's edge turns red too), else the
/// help; never two. VoiceOver reads the row's label for its control, and the line as its hint.
public struct SettingsRow<Trailing: View>: View {
    let label: String
    var help: String?
    var error: String?
    var disabledReason: String?
    let control: Trailing

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        _ label: String, help: String? = nil, error: String? = nil, disabledReason: String? = nil,
        @ViewBuilder control: () -> Trailing
    ) {
        self.label = label
        self.help = help
        self.error = error
        self.disabledReason = disabledReason
        self.control = control()
    }

    private var footnote: DesignTokens.Field.Footnote? {
        DesignTokens.SettingsRow.footnote(help: help, error: error, disabledReason: disabledReason)
    }

    private var disabled: Bool { if case .reason? = footnote { true } else { false } }
    private var invalid: Bool { if case .error? = footnote { true } else { false } }

    public var body: some View {
        let tokens = DesignTokens.SettingsRow.self
        HStack(alignment: .center, spacing: tokens.columnGap) {
            VStack(alignment: .leading, spacing: tokens.lineGap) {
                Text(label)
                    .font(DesignTokens.TypeStyle.font(size: tokens.labelSize, weight: tokens.labelWeight))
                    .foregroundStyle(tokens.label(disabled: disabled).color)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityHidden(true)
                if let footnote {
                    FieldFootnote(footnote: footnote)
                        .frame(maxWidth: DesignTokens.Measure.width(DesignTokens.Measure.narrowCharacters, for: .secondary), alignment: .leading)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control
                .environment(\.settingsRowLabel, label)
                .environment(\.settingsRowInvalid, invalid)
                .disabled(disabled)
                .notAllowedPointer(disabled)
                .help(disabledReason ?? "")
                .accessibilityHint(Self.spokenHint(footnote))
        }
        .padding(.vertical, tokens.verticalPadding)
        .padding(.horizontal, tokens.horizontalPadding)
        .animation(.motion(.standard, reduceMotion: reduceMotion), value: footnote)
        .accessibilityElement(children: .contain)
    }

    /// What VoiceOver reads after the control: the line under the label.
    static func spokenHint(_ footnote: DesignTokens.Field.Footnote?) -> String {
        switch footnote {
        case let .reason(text)?, let .error(text)?, let .help(text)?: text
        case nil: ""
        }
    }
}

/// A group of settings: its rows on one content card, a hairline between two of them, under the group's title in small
/// capitals and over its footer, the line that says what the group is for. A title or footer that is nil or blank is
/// not drawn.
public struct SettingsGroup<Content: View>: View {
    let title: String?
    let footer: String?
    let content: Content

    public init(_ title: String? = nil, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    public var body: some View {
        let tokens = DesignTokens.SettingsRow.self
        let shape = RoundedRectangle(cornerRadius: tokens.radius, style: .continuous)
        VStack(alignment: .leading, spacing: tokens.groupGap) {
            if let title = Self.shown(title) {
                Text(title.uppercased())
                    .tracking(CGFloat(tokens.titleTracking * DesignTokens.TypeStyle.caption.size))
                    .textStyle(.caption)
                    .foregroundStyle(DesignTokens.TextColor.secondary.color)
                    .padding(.horizontal, tokens.horizontalPadding)
                    .accessibilityAddTraits(.isHeader)
            }
            VStack(alignment: .leading, spacing: 0) {
                Group(subviews: content) { rows in
                    ForEach(rows.indices, id: \.self) { index in
                        if index > 0 {
                            HairlineDivider().padding(.leading, tokens.horizontalPadding)
                        }
                        rows[index]
                    }
                }
            }
            .background { shape.fill(tokens.surface.color) }
            .elevation(tokens.elevation, in: shape)
            if let footer = Self.shown(footer) {
                Text(footer)
                    .textStyle(.secondary)
                    .foregroundStyle(DesignTokens.TextColor.secondary.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, tokens.horizontalPadding)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Self.shown(title) ?? "")
    }

    /// A title or footer that has words.
    static func shown(_ text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }
}

/// A line of a group that is no one setting: the words that explain the rows around it, a status beside its action, an
/// error that names where its reason shows, or a row of fields such as a variable's name and value. It is padded as a
/// row, so the group draws its hairlines around it as around a row.
public struct SettingsLine<Content: View>: View {
    let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        let tokens = DesignTokens.SettingsRow.self
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, tokens.verticalPadding)
            .padding(.horizontal, tokens.horizontalPadding)
    }
}

extension SettingsLine where Content == FieldFootnote {
    /// The words of a line: the help in the secondary colour, or an error in the problem colour.
    public init(_ text: String, error: Bool = false) {
        self.init { FieldFootnote(footnote: error ? .error(text) : .help(text)) }
    }
}
