import SwiftUI
import SymphonyBarCore

// The catalog's Save bar (`components/save-bar`, `.save-bar`; TP-1530): the bar over a page that is edited whole and
// saved at once, such as Factory › Runs.

/// Where a save stands, beside the count of changes.
public enum SaveBarState: Equatable {
    /// Editing: the count of changes not saved, or nothing with none.
    case editing
    /// The save is under way: "Saving…", and Save is off.
    case saving
    /// Just saved: "Saved" with a check, while nothing is left to save. The page takes it away after
    /// `DesignTokens.SaveBar.savedFor` seconds.
    case saved
    /// The save was refused: why, in the problem colour; every change stays.
    case refused(String)
}

/// The catalog's Save bar: glass at the top of a page edited whole, what is edited on the left (`leading`, such as
/// the For pop-up), then how much is not saved, Revert and Save on the right, with ⌘S beside it. Nothing the page
/// shows is applied until Save; Save is off while nothing has changed or a save is under way, and while
/// `saveDisabledReason` says why it can't save yet (a value out of range), with the reason as its help. A refused save
/// keeps every change and says why in the bar. The count is announced when it changes.
public struct SaveBar<Leading: View>: View {
    let changes: Int
    let state: SaveBarState
    let saveDisabledReason: String?
    let onRevert: () -> Void
    let onSave: () -> Void
    let leading: Leading
    @Environment(\.offscreenSnapshot) private var offscreenSnapshot
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        changes: Int, state: SaveBarState = .editing, saveDisabledReason: String? = nil, onRevert: @escaping () -> Void,
        onSave: @escaping () -> Void, @ViewBuilder leading: () -> Leading
    ) {
        self.changes = max(0, changes)
        self.state = state
        self.saveDisabledReason = saveDisabledReason
        self.onRevert = onRevert
        self.onSave = onSave
        self.leading = leading()
    }

    /// Whether Save can be pressed: something changed, no save is under way and nothing keeps it from saving.
    var canSave: Bool { changes > 0 && state != .saving && saveDisabledReason == nil }
    /// Whether Revert shows: something changed and no save is under way.
    var showsRevert: Bool { changes > 0 && state != .saving }

    public var body: some View {
        let bar = DesignTokens.SaveBar.self
        let shape = RoundedRectangle(cornerRadius: bar.radius, style: .continuous)
        HStack(spacing: bar.gap) {
            leading
            Spacer(minLength: 0)
            status
            if showsRevert {
                Button("Revert", action: onRevert)
                    .buttonStyle(DirectorButtonStyle(kind: .quiet, size: .small))
                    .transition(.opacity)
            }
            Button("Save", action: onSave)
                .buttonStyle(DirectorButtonStyle(kind: .primary, size: .small))
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!canSave)
                .notAllowedPointer(saveDisabledReason != nil)
                .help(saveDisabledReason ?? "")
                .accessibilityHint(saveDisabledReason ?? "")
            KeyboardHint(bar.shortcut, plain: true)
        }
        .padding(.vertical, bar.verticalPadding)
        .padding(.horizontal, bar.horizontalPadding)
        .background {
            if offscreenSnapshot || reduceTransparency {
                shape.fill(bar.glass.solid.color)
            } else {
                Color.clear.glassBackground(bar.glass, in: shape)
            }
        }
        .edgeHighlight(shape)
        .elevation(bar.elevation, in: shape)
        .animation(.motion(.standard, reduceMotion: reduceMotion), value: changes > 0)
        .onChange(of: changes) { _, count in
            AccessibilityNotification.Announcement(DesignTokens.SaveBar.unsaved(count) ?? "No changes").post()
        }
    }

    @ViewBuilder private var status: some View {
        let bar = DesignTokens.SaveBar.self
        switch state {
        case .saving:
            count(bar.saving)
        case let .refused(reason):
            HStack(spacing: bar.glyphGap) {
                glyph(bar.refusedSymbol)
                Text(reason).textStyle(.secondary).lineLimit(1)
            }
            .foregroundStyle(DesignTokens.Status.problem.text)
        case .saved where changes == 0:
            HStack(spacing: bar.glyphGap) {
                glyph(bar.savedSymbol)
                Text(bar.saved).textStyle(.secondary)
            }
            .foregroundStyle(DesignTokens.Status.done.text)
            .padding(.trailing, bar.countTrailing)
            .transition(.opacity)
        case .editing, .saved:
            if let unsaved = bar.unsaved(changes) {
                count(unsaved).transition(.opacity)
            }
        }
    }

    private func count(_ text: String) -> some View {
        Text(text)
            .textStyle(.secondary)
            .monospacedDigit()
            .foregroundStyle(DesignTokens.TextColor.secondary.color)
            .lineLimit(1)
            .padding(.trailing, DesignTokens.SaveBar.countTrailing)
    }

    private func glyph(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(DesignTokens.TypeStyle.font(size: DesignTokens.SaveBar.glyph, weight: DesignTokens.TypeStyle.label.weight))
            .accessibilityHidden(true)
    }
}

extension SaveBar where Leading == EmptyView {
    /// A Save bar with nothing on its left.
    public init(
        changes: Int, state: SaveBarState = .editing, saveDisabledReason: String? = nil, onRevert: @escaping () -> Void,
        onSave: @escaping () -> Void
    ) {
        self.init(changes: changes, state: state, saveDisabledReason: saveDisabledReason, onRevert: onRevert, onSave: onSave) {
            EmptyView()
        }
    }
}
