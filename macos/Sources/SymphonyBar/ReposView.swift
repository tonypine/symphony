import SwiftUI
import SymphonyBarCore

/// One row per connected repo, as `ReposList` describes them.
struct ReposView: View {
    static let width: CGFloat = 640

    @ObservedObject var model: ReposViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.message ?? "")
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button(AddRepo.buttonTitle) { model.onAddRepo() }
            }
            .padding(12)
            Divider()
            if let notice = model.display.notice {
                Text(notice)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
                Divider()
            }
            List(model.display.rows) { row in
                RepoRowView(
                    row: row,
                    edit: { model.onEdit(row.key) },
                    disconnect: { model.onDisconnect(row.key) },
                    removeClone: { model.onRemoveClone(row.key) }
                )
            }
        }
        .frame(minWidth: 480, idealWidth: Self.width, minHeight: 320)
        .sheet(isPresented: Binding(get: { model.addRepo != nil }, set: { if !$0 { model.addRepo = nil } })) {
            if let addRepo = model.addRepo {
                AddRepoView(model: addRepo) { model.addRepo = nil }
            }
        }
    }
}

struct RepoRowView: View {
    let row: RepoRow
    let edit: () -> Void
    let disconnect: () -> Void
    let removeClone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(row.key).font(.headline)
                if row.isDefault {
                    Text(ReposList.defaultMarker)
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.2)))
                        .help(ReposList.defaultHelp)
                }
                Spacer()
                HStack(spacing: 6) { actions }
                    .controlSize(.small)
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 3) {
                ForEach(row.fields, id: \.label) { field in
                    GridRow {
                        Text(field.label)
                            .foregroundStyle(.secondary)
                            .gridColumnAlignment(.trailing)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(field.value).foregroundStyle(color(field.tone))
                            if let detail = field.detail {
                                Text(detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                                    .truncationMode(.middle)
                                    .textSelection(.enabled)
                            }
                        }
                        .help(field.detail ?? field.value)
                    }
                }
            }
            ForEach(row.actions.notes, id: \.self) { note in
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder private var actions: some View {
        Button(EditRepo.buttonTitle, action: edit)
            .disabled(row.actions.editProblem != nil)
            .help(row.actions.editProblem ?? "Change where the code comes from, the base branch and the Linear route.")
        Button(DisconnectRepo.buttonTitle, action: disconnect)
            .disabled(row.actions.disconnectProblem != nil)
            .help(row.actions.disconnectProblem ?? "Remove the repo from symphony.yml. No folder is deleted.")
        if let removal = row.actions.cloneRemoval {
            Button(ManagedClones.buttonTitle, action: removeClone)
                .disabled(removal.path == nil)
                .help(cloneRemovalHelp(removal))
        }
    }

    private func cloneRemovalHelp(_ removal: ManagedClones.Removal) -> String {
        switch removal {
        case let .allowed(path):
            return "Delete Symphony's clone at \((path as NSString).abbreviatingWithTildeInPath)."
        case let .blocked(reason):
            return reason
        }
    }

    private func color(_ tone: RepoField.Tone) -> Color {
        switch tone {
        case .normal:
            return .primary
        case .unavailable:
            return .secondary
        case .problem:
            return .red
        }
    }
}
