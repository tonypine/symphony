import SwiftUI
import SymphonyBarCore

/// C17 (P5, D12d): the consequence sheet of a move. The title is the question; then what happens in Linear, what
/// stays the same, the options (the picks posted, Rework's required reason), and Cancel with the verb. A spinner
/// shows while the move is on its way, and what went wrong shows inline.
struct ConsequenceSheetView: View {
    let sheet: ConsequenceSheet
    let working: Bool
    let error: String?
    let cancel: () -> Void
    let confirm: (String) -> Void
    @State private var reason = ""
    @FocusState private var reasonFocused: Bool

    init(sheet: ConsequenceSheet, working: Bool, error: String?, reason: String = "", cancel: @escaping () -> Void, confirm: @escaping (String) -> Void) {
        self.sheet = sheet
        self.working = working
        self.error = error
        self.cancel = cancel
        self.confirm = confirm
        _reason = State(initialValue: reason)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s4) {
            Text(sheet.title)
                .font(DesignTokens.TypeStyle.sentence.font)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(sheet.happens)
                .font(DesignTokens.TypeStyle.body.font)
                .foregroundStyle(sheet.isDestructive ? AnyShapeStyle(DesignTokens.Status.problem.tint) : AnyShapeStyle(.primary))
                .fixedSize(horizontal: false, vertical: true)
            Text(sheet.stays)
                .font(DesignTokens.TypeStyle.body.font)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !sheet.picks.isEmpty {
                VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
                    Text("Your picks").font(DesignTokens.TypeStyle.label.font).foregroundStyle(.secondary)
                    ForEach(Array(sheet.picks.enumerated()), id: \.offset) { index, pick in
                        Text("\(index + 1). \(pick.question) \(Text(pick.answer).bold())")
                            .font(DesignTokens.TypeStyle.body.font)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(DesignTokens.Space.s3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DesignTokens.Surface.raised.color, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.row, style: .continuous))
            }
            if sheet.needsReason {
                VStack(alignment: .leading, spacing: DesignTokens.Space.s1) {
                    Text(sheet.reasonPrompt).font(DesignTokens.TypeStyle.label.font)
                    TextField("Reason (required)", text: $reason, axis: .vertical)
                        .lineLimit(3...6)
                        .textFieldStyle(.roundedBorder)
                        .focused($reasonFocused)
                        .accessibilityLabel(sheet.reasonPrompt)
                }
            }
            if let error {
                Label(error, systemImage: DesignTokens.Status.problem.symbol)
                    .font(DesignTokens.TypeStyle.callout.font)
                    .foregroundStyle(DesignTokens.Status.problem.tint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: DesignTokens.Space.s2) {
                if working {
                    ProgressView().controlSize(.small).accessibilityLabel("Working")
                }
                Spacer(minLength: 0)
                Button("Cancel", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                    .disabled(working)
                Button(sheet.verb, role: sheet.isDestructive ? .destructive : nil) { confirm(reason) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(sheet.isDestructive ? DesignTokens.Status.problem.tint : nil)
                    .disabled(working || !sheet.canSend(reason: reason))
            }
        }
        .padding(DesignTokens.Space.s5)
        .frame(width: 460)
        .onAppear { reasonFocused = sheet.needsReason }
    }
}

/// C18: the banner at the foot of the Inbox after a move, with Undo for 10 s and a close button.
struct InboxBannerView: View {
    let banner: InboxBanner
    let undo: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: DesignTokens.Space.s3) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text("\(Text(banner.identifier).bold())  \(banner.text)")
                .font(DesignTokens.TypeStyle.body.font)
                .lineLimit(2)
            Spacer(minLength: DesignTokens.Space.s2)
            if banner.undo {
                Button("Undo", action: undo)
            }
            Button(action: close) {
                Image(systemName: "xmark").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, DesignTokens.Space.s4)
        .padding(.vertical, DesignTokens.Space.s3)
        .background(DesignTokens.Surface.raised.color, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous)
                .strokeBorder(DesignTokens.Surface.separator.color)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(banner.announcement)
    }

    private var symbol: String {
        switch banner.style {
        case .success: DesignTokens.Status.done.symbol
        case .info: "arrow.uturn.backward.circle"
        case .error: DesignTokens.Status.problem.symbol
        }
    }

    private var tint: Color {
        switch banner.style {
        case .success: DesignTokens.Status.done.tint
        case .info: .secondary
        case .error: DesignTokens.Status.problem.tint
        }
    }
}
