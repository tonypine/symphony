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
                RepoRowView(row: row)
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

private struct RepoRowView: View {
    let row: RepoRow

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
        }
        .padding(.vertical, 6)
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
