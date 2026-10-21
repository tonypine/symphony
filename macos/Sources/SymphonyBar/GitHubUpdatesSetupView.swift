import SwiftUI
import SymphonyBarCore

/// What the guided setup's controls do.
struct GitHubUpdatesSetupActions {
    var pick: (String) -> Void = { _ in }
    var setURL: (String) -> Void = { _ in }
    var perform: (GitHubUpdatesSetup.Button, _ rowID: String) -> Void = { _, _ in }
    var back: () -> Void = {}
    var forward: () -> Void = {}
    var cancel: () -> Void = {}
}

/// S2–S6 (C17's sheet, 520 pt with a fixed footer): "Step 2 of 5" and the page's title, the five steps with those done
/// ticked, what the page does and why, then the relays to pick or the page's rows, each done, working or failed with
/// its fix and buttons. The footer keeps Cancel, Back and Continue (Done on the last page) in place on every page.
struct GitHubUpdatesSetupView: View {
    static let size = CGSize(width: 520, height: 520)

    let setup: GitHubUpdatesSetup
    var actions = GitHubUpdatesSetupActions()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding([.top, .horizontal], DesignTokens.Space.s4)
                .padding(.bottom, DesignTokens.Space.s3)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: DesignTokens.Space.s4) {
                    Text(setup.explanation)
                        .font(DesignTokens.TypeStyle.body.font)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if setup.page == .relay {
                        relays
                    } else {
                        GitHubUpdatesSetupRows(rows: setup.rows, perform: actions.perform)
                    }
                }
                .padding(DesignTokens.Space.s4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
            Text(setup.stepLabel)
                .font(DesignTokens.TypeStyle.caption.font)
                .foregroundStyle(.secondary)
            Text(setup.page.title)
                .font(DesignTokens.TypeStyle.section.font)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            GitHubUpdatesSetupIndicator(current: setup.page, done: setup.donePages)
        }
    }

    // MARK: S2

    private var relays: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
            ForEach(setup.relayOptions) { option in
                RelayOptionRow(option: option, selected: option.id == setup.relay) { actions.pick(option.id) }
                    .disabled(setup.running.contains("turn_on"))
            }
            if setup.needsURL {
                TextField("Public URL", text: Binding(get: { setup.url }, set: actions.setURL), prompt: Text("https://smee.io/…"))
                    .textFieldStyle(.roundedBorder)
                    .disabled(setup.running.contains("turn_on"))
                    .accessibilityLabel("The relay's public URL")
            }
            if let error = setup.turnOnError {
                Label(error, systemImage: DesignTokens.Status.problem.symbol)
                    .font(DesignTokens.TypeStyle.callout.font)
                    .foregroundStyle(DesignTokens.Status.problem.tint)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: DesignTokens.Space.s2) {
            Button(GitHubUpdatesSetup.cancelTitle, role: .cancel, action: actions.cancel)
                .keyboardShortcut(.cancelAction)
            Spacer(minLength: DesignTokens.Space.s2)
            if let problem = setup.continueProblem {
                Text(problem)
                    .font(DesignTokens.TypeStyle.callout.font)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.trailing)
            }
            if setup.page != .relay {
                Button(GitHubUpdatesSetup.backTitle, action: actions.back)
                    .disabled(!setup.canGoBack)
            }
            Button(setup.continueTitle, action: actions.forward)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!setup.canContinue)
                .help(setup.continueProblem ?? "")
        }
        .padding(DesignTokens.Space.s3)
    }
}

/// "1 Relay › 2 GitHub CLI › 3 Secret and port › 4 Repos › 5 Test": the page shown in bold, the pages done ticked.
struct GitHubUpdatesSetupIndicator: View {
    let current: GitHubUpdatesSetup.Page
    let done: Set<GitHubUpdatesSetup.Page>

    var body: some View {
        HStack(spacing: DesignTokens.Space.s1) {
            ForEach(GitHubUpdatesSetup.Page.allCases, id: \.self) { page in
                if page != .relay {
                    Image(systemName: "chevron.right")
                        .font(DesignTokens.TypeStyle.caption.font)
                        .foregroundStyle(.tertiary)
                }
                HStack(spacing: 3) {
                    if done.contains(page) {
                        Image(systemName: DesignTokens.Status.done.symbol).foregroundStyle(DesignTokens.Status.done.tint)
                    } else {
                        Text("\(page.rawValue)").monospacedDigit()
                    }
                    Text(page.shortName)
                }
                .font(DesignTokens.TypeStyle.callout.font)
                .fontWeight(page == current ? .semibold : .regular)
                .foregroundStyle(page == current ? .primary : .secondary)
                .lineLimit(1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "Step \(current.rawValue) of \(GitHubUpdatesSetup.Page.allCases.count): \(current.shortName)"
                + (done.isEmpty ? "" : ". Done: " + GitHubUpdatesSetup.Page.allCases.filter(done.contains).map(\.shortName).joined(separator: ", "))
        )
    }
}

/// One relay on S2 (as an N7 option card): a radio, the label with Recommended on the recommended one, and what it takes.
private struct RelayOptionRow: View {
    let option: GitHubUpdatesSheet.RelayOption
    let selected: Bool
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.s3) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                VStack(alignment: .leading, spacing: DesignTokens.Space.s1) {
                    HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.s2) {
                        Text(option.label).font(DesignTokens.TypeStyle.rowTitle.font)
                        if option.recommended { RecommendedBadge() }
                    }
                    Text(option.summary)
                        .font(DesignTokens.TypeStyle.callout.font)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(DesignTokens.Space.s3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                selected ? AnyShapeStyle(Color.accentColor.opacity(0.07)) : AnyShapeStyle(DesignTokens.Surface.content.color),
                in: RoundedRectangle(cornerRadius: DesignTokens.Radius.row, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.row, style: .continuous)
                    .strokeBorder(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(DesignTokens.Surface.separator.color), lineWidth: selected ? 2 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.row, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([option.label, option.recommended ? GitHubUpdatesSetup.recommended : nil, option.summary].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// The rows of a setup page, and of Add Repo's Instant updates step: the state's symbol (a spinner while it works), the
/// title and its word, what it went through or what is wrong, the fix, and the row's buttons.
struct GitHubUpdatesSetupRows: View {
    let rows: [GitHubUpdatesSetup.Row]
    var perform: (GitHubUpdatesSetup.Button, _ rowID: String) -> Void = { _, _ in }
    @Environment(\.offscreenSnapshot) private var offscreenSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s3) {
            ForEach(rows) { row in
                HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.s3) {
                    symbol(row)
                        .frame(width: 18)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: DesignTokens.Space.s1) {
                        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.s2) {
                            Text(row.title).font(DesignTokens.TypeStyle.rowTitle.font)
                            Text(row.word).font(DesignTokens.TypeStyle.callout.font).foregroundStyle(row.tone.status.tint)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(row.accessibilityLabel)
                        if let detail = row.detail {
                            Text(detail)
                                .font(DesignTokens.TypeStyle.callout.font)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityHidden(true)
                        }
                        if let fix = row.fix {
                            Text(fix)
                                .font(DesignTokens.TypeStyle.callout.font)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityHidden(true)
                        }
                        if !row.buttons.isEmpty {
                            HStack(spacing: DesignTokens.Space.s2) {
                                ForEach(row.buttons, id: \.self) { button in
                                    Button(button.title) { perform(button, row.id) }
                                        .controlSize(.small)
                                        .buttonStyle(.bordered)
                                        .accessibilityLabel("\(button.title.replacingOccurrences(of: "…", with: "")), \(row.title)")
                                }
                            }
                            .padding(.top, DesignTokens.Space.s1 / 2)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .contain)
            }
        }
    }

    @ViewBuilder private func symbol(_ row: GitHubUpdatesSetup.Row) -> some View {
        if row.isWorking, !offscreenSnapshot {
            ProgressView().controlSize(.small)
        } else {
            Image(systemName: row.tone.symbol).foregroundStyle(row.tone.status.tint)
        }
    }
}
