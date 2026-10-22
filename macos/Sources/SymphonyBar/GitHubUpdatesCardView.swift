import SwiftUI
import SymphonyBarCore

/// What the GitHub updates card's buttons do.
struct GitHubUpdatesCardActions {
    var perform: (GitHubUpdatesCard.Action) -> Void = { _ in }
    /// Saves the two intervals under Details; answers whether it saved.
    var saveIntervals: (_ safetyNetMinutes: Int, _ silenceAlertMinutes: Int) async -> Bool = { _, _ in false }
    /// True while Restart Relay is on its way.
    var restarting = false
}

/// S1, S7, S8, S10, S14, S18 (C10): the GitHub updates card on the Setup page. Its state reads as a symbol and a word,
/// then a sentence; each repo with its last update; the setup steps while setup isn't finished; Details with the relay,
/// the secret, the two intervals, the events and the address.
struct GitHubUpdatesCardView: View {
    let card: GitHubUpdatesCard
    var actions = GitHubUpdatesCardActions()
    @State private var expanded: Bool

    init(card: GitHubUpdatesCard, actions: GitHubUpdatesCardActions = GitHubUpdatesCardActions(), startsExpanded: Bool = false) {
        self.card = card
        self.actions = actions
        _expanded = State(initialValue: startsExpanded)
    }

    var body: some View {
        Card(title: GitHubUpdatesCard.title) {
            VStack(alignment: .leading, spacing: DesignTokens.Space.s3) {
                header
                Text(card.sentence)
                    .font(DesignTokens.TypeStyle.body.font)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let requests = card.requests {
                    Label {
                        Text(requests.sentence).font(DesignTokens.TypeStyle.callout.font).fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: requests.tone.symbol).foregroundStyle(requests.tone.status.tint)
                    }
                    .accessibilityElement(children: .combine)
                }
                if !card.repos.isEmpty {
                    rows(card.repos.map { ($0.id, $0.name, $0.tone, $0.word, Optional($0.detail)) })
                }
                if !card.steps.isEmpty {
                    rows(card.steps.map { ($0.id, $0.title, $0.tone, $0.word, $0.detail) })
                }
                if card.showsDetails {
                    Button {
                        withAnimation(.standard) { expanded.toggle() }
                    } label: {
                        Label(SetupPage.detailsTitle, systemImage: expanded ? "chevron.down" : "chevron.right")
                            .font(DesignTokens.TypeStyle.callout.font)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(expanded ? "Hide GitHub updates details" : "Show GitHub updates details")
                    if expanded {
                        GitHubUpdatesDetails(card: card, actions: actions)
                    }
                }
            }
        }
    }

    /// The state's symbol and word, then the card's buttons.
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.s2) {
            Label {
                Text(card.word).font(DesignTokens.TypeStyle.rowTitle.font)
            } icon: {
                Image(systemName: card.tone.symbol).foregroundStyle(card.tone.status.tint)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(card.accessibilityLabel)
            Spacer(minLength: DesignTokens.Space.s2)
            if actions.restarting {
                ProgressView().controlSize(.small).accessibilityLabel("Restarting the relay")
            }
            if let primary = card.primary {
                Button(primary.title) { actions.perform(primary) }
                    .buttonStyle(.borderedProminent)
                    .disabled(primary == .restartRelay && actions.restarting)
                    .fixedSize()
            }
            ForEach(card.secondary, id: \.self) { action in
                Button(action.title) { actions.perform(action) }
                    .buttonStyle(.bordered)
                    .fixedSize()
            }
        }
    }

    private func rows(_ rows: [(id: String, title: String, tone: GitHubUpdatesCard.Tone, word: String, detail: String?)]) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
            ForEach(rows, id: \.id) { row in
                HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.s3) {
                    Image(systemName: row.tone.symbol)
                        .foregroundStyle(row.tone.status.tint)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: DesignTokens.Space.s1 / 2) {
                        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.s2) {
                            Text(row.title).font(DesignTokens.TypeStyle.rowTitle.font)
                            Text(row.word).font(DesignTokens.TypeStyle.callout.font).foregroundStyle(row.tone.status.tint)
                        }
                        if let detail = row.detail {
                            Text(detail)
                                .font(DesignTokens.TypeStyle.callout.font)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel([row.title, row.word, row.detail].compactMap { $0 }.joined(separator: ", "))
            }
        }
    }
}

/// Details: the relay with Change Relay…, the secret with Re-create Secret…, the two intervals with Settings' own
/// steppers, the events (read-only) and the address.
private struct GitHubUpdatesDetails: View {
    let card: GitHubUpdatesCard
    let actions: GitHubUpdatesCardActions
    @Environment(\.offscreenSnapshot) private var offscreenSnapshot
    @State private var safetyNet: Int
    @State private var silenceAlert: Int
    @State private var saving = false

    init(card: GitHubUpdatesCard, actions: GitHubUpdatesCardActions) {
        self.card = card
        self.actions = actions
        _safetyNet = State(initialValue: card.safetyNetMinutes)
        _silenceAlert = State(initialValue: card.silenceAlertMinutes)
    }

    private var changed: Bool { safetyNet != card.safetyNetMinutes || silenceAlert != card.silenceAlertMinutes }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: DesignTokens.Space.s3, verticalSpacing: DesignTokens.Space.s2) {
                ForEach(card.details) { detail in
                    GridRow {
                        Text(detail.label)
                            .font(DesignTokens.TypeStyle.callout.font)
                            .foregroundStyle(.secondary)
                        Text(detail.value)
                            .font(detail.label == "Address" || detail.label == "Events" ? DesignTokens.TypeStyle.mono.font : DesignTokens.TypeStyle.body.font)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let action = detail.action {
                            Button(action.title) { actions.perform(action) }
                                .controlSize(.small)
                                .fixedSize()
                        } else {
                            Color.clear.frame(width: 0, height: 0)
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("\(detail.label), \(detail.value)")
                }
            }
            interval("Safety-net check every", minutes: $safetyNet)
            interval("Warn me after no updates for", minutes: $silenceAlert)
            if changed {
                HStack(spacing: DesignTokens.Space.s2) {
                    Spacer(minLength: 0)
                    if saving { ProgressView().controlSize(.small).accessibilityLabel("Saving") }
                    Button("Revert") {
                        safetyNet = card.safetyNetMinutes
                        silenceAlert = card.silenceAlertMinutes
                    }
                    .disabled(saving)
                    Button("Save") { save() }
                        .buttonStyle(.borderedProminent)
                        .disabled(saving)
                }
            }
        }
        .padding(.leading, DesignTokens.Space.s4)
        // A poll that brings new values moves the steppers too, unless they hold an unsaved change.
        .onChange(of: card.safetyNetMinutes) { _, minutes in if !saving { safetyNet = minutes } }
        .onChange(of: card.silenceAlertMinutes) { _, minutes in if !saving { silenceAlert = minutes } }
    }

    /// Settings' stepper, or its words alone offscreen, where the AppKit stepper can't draw.
    @ViewBuilder private func interval(_ title: String, minutes: Binding<Int>) -> some View {
        if offscreenSnapshot {
            Text("\(title) \(minutes.wrappedValue) min").font(DesignTokens.TypeStyle.body.font)
        } else {
            MinutesRow(title: title, minutes: minutes)
        }
    }

    private func save() {
        saving = true
        Task {
            _ = await actions.saveIntervals(safetyNet, silenceAlert)
            saving = false
        }
    }
}

/// S11, S12 and the relay sheet (P5, C17): the question, what happens, what stays, the relay to pick when there is one,
/// and Cancel with the verb. A spinner shows while it works; a failure shows inline with Close and Try Again.
struct GitHubUpdatesSheetView: View {
    let sheet: GitHubUpdatesSheet
    var change: (GitHubUpdatesSheet) -> Void = { _ in }
    let cancel: () -> Void
    let confirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s4) {
            Text(sheet.title)
                .font(DesignTokens.TypeStyle.sentence.font)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(sheet.happens)
                .font(DesignTokens.TypeStyle.body.font)
                .fixedSize(horizontal: false, vertical: true)
            if sheet.picksRelay { relayPicker }
            Text(sheet.stays)
                .font(DesignTokens.TypeStyle.body.font)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error = sheet.error {
                Label(error, systemImage: DesignTokens.Status.problem.symbol)
                    .font(DesignTokens.TypeStyle.callout.font)
                    .foregroundStyle(DesignTokens.Status.problem.tint)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: DesignTokens.Space.s2) {
                if sheet.isWorking {
                    ProgressView().controlSize(.small).accessibilityLabel("Working")
                }
                Spacer(minLength: 0)
                Button(sheet.cancelTitle, role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                    .disabled(sheet.isWorking)
                Button(sheet.confirmTitle, role: sheet.isDestructive ? .destructive : nil, action: confirm)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!sheet.canConfirm)
            }
        }
        .padding(DesignTokens.Space.s5)
        .frame(width: 520)
    }

    private var relayPicker: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
            Picker("Relay", selection: binding(\.relay)) {
                ForEach(GitHubUpdatesSheet.relays) { option in
                    Text(option.label).tag(option.id)
                }
            }
            .pickerStyle(.radioGroup)
            .disabled(sheet.isWorking)
            if let option = sheet.option {
                Text(option.note)
                    .font(DesignTokens.TypeStyle.callout.font)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if sheet.needsURL {
                TextField("Public URL", text: binding(\.url), prompt: Text("https://smee.io/…"))
                    .textFieldStyle(.roundedBorder)
                    .disabled(sheet.isWorking)
                    .accessibilityLabel("The relay's public URL")
            }
        }
    }

    private func binding(_ keyPath: WritableKeyPath<GitHubUpdatesSheet, String>) -> Binding<String> {
        Binding(get: { sheet[keyPath: keyPath] }, set: { value in
            var edited = sheet
            edited[keyPath: keyPath] = value
            change(edited)
        })
    }
}
