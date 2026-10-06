import SwiftUI
import SymphonyBarCore

/// The open Disconnect sheet for one repo: its text, the pick of the new default and whether to delete its clone.
@MainActor
final class DisconnectSheetModel: ObservableObject, Identifiable {
    let content: DisconnectRepo.Sheet
    @Published var newDefault: String
    @Published var deleteClone = false
    /// The repo's key.
    nonisolated let id: String

    init(_ content: DisconnectRepo.Sheet) {
        self.content = content
        id = content.key
        newDefault = content.candidates?.first ?? ""
    }
}

/// S10: asks before disconnecting a repo, says what stays on disk, picks the new default and can delete Symphony's
/// clone in the same step. The checkbox follows each poll, so it turns off once a run starts on the clone.
struct DisconnectRepoView: View {
    static let width: CGFloat = 440

    @ObservedObject var sheet: DisconnectSheetModel
    /// The repo as the window shows it now, for its clone's removal state.
    let repo: RepoDetail?
    let cancel: () -> Void
    let confirm: () -> Void

    var body: some View {
        let clone = repo.flatMap(DisconnectRepo.cloneOption)
        VStack(alignment: .leading, spacing: 12) {
            Text(sheet.content.title)
                .font(.headline)
            Text(sheet.content.message)
                .fixedSize(horizontal: false, vertical: true)
            if let candidates = sheet.content.candidates {
                Picker(DisconnectRepo.newDefaultTitle, selection: $sheet.newDefault) {
                    ForEach(candidates, id: \.self) { Text($0).tag($0) }
                }
                .fixedSize()
            }
            if let clone {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(isOn: Binding(get: { sheet.deleteClone && clone.isEnabled }, set: { sheet.deleteClone = $0 })) {
                        Text(clone.title)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .help(clone.path ?? clone.title)
                    }
                    .disabled(!clone.isEnabled)
                    if let reason = clone.reason {
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.leading, 20)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                // A bordered macOS button ignores the role and the label's colour; a red tint on a prominent one shows.
                Button(DisconnectRepo.confirmTitle, role: .destructive) {
                    // Deletes the clone only when the box shows checked: a clone that turned busy shows it off.
                    if clone?.isEnabled != true { sheet.deleteClone = false }
                    confirm()
                }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
            }
            .padding(.top, 4)
        }
        .padding(20)
        .frame(width: Self.width, alignment: .leading)
    }
}
