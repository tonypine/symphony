import SwiftUI
import SymphonyBarCore

// Factory › Runs (TP-1538), as the catalog draws it (`runsPage`, `.runs-page`): the Save bar with For on its left, then
// one panel with Default and the nine kinds of run, each always open, each a Reorderable list of its first choice and
// fallbacks. Built from the shared Save bar, Pop-up, Searchable pop-up and Reorderable list (TP-1530, TP-1531).

/// What the page asks of whoever holds it. Every edit changes the page's values only; Save writes them.
public struct RunsPageActions {
    public var show: (RunProfilesScope) -> Void
    public var pick: (_ kind: RunKind?, _ line: Int, _ field: RunProfileField, _ value: String?) -> Void
    public var useDefaults: (RunKind?) -> Void
    public var addFallback: (RunKind?) -> Void
    public var remove: (_ kind: RunKind?, _ line: Int) -> Void
    public var reorder: (_ kind: RunKind?, _ order: [Int]) -> Void
    public var revert: () -> Void
    public var save: () -> Void

    public init(
        show: @escaping (RunProfilesScope) -> Void, pick: @escaping (RunKind?, Int, RunProfileField, String?) -> Void,
        useDefaults: @escaping (RunKind?) -> Void, addFallback: @escaping (RunKind?) -> Void, remove: @escaping (RunKind?, Int) -> Void,
        reorder: @escaping (RunKind?, [Int]) -> Void, revert: @escaping () -> Void, save: @escaping () -> Void
    ) {
        self.show = show
        self.pick = pick
        self.useDefaults = useDefaults
        self.addFallback = addFallback
        self.remove = remove
        self.reorder = reorder
        self.revert = revert
        self.save = save
    }

    /// Actions that do nothing, for a still picture.
    public static var none: RunsPageActions {
        RunsPageActions(
            show: { _ in }, pick: { _, _, _, _ in }, useDefaults: { _ in }, addFallback: { _ in }, remove: { _, _ in },
            reorder: { _, _ in }, revert: {}, save: {}
        )
    }
}

/// A still state of the page, for a story: a model list drawn open on a line, and a line drawn lifted.
public struct RunsPageDrawn: Equatable {
    /// The row (`RunsPage.Row.id`) and the line (0 for the first choice) whose Model list is open, and what is typed.
    public var modelOpen: (row: String, line: Int)?
    public var query: String
    /// The row and line drawn being dragged.
    public var dragging: (row: String, line: Int)?

    public init(modelOpen: (row: String, line: Int)? = nil, query: String = "", dragging: (row: String, line: Int)? = nil) {
        self.modelOpen = modelOpen
        self.query = query
        self.dragging = dragging
    }

    public static func == (lhs: RunsPageDrawn, rhs: RunsPageDrawn) -> Bool {
        lhs.modelOpen?.row == rhs.modelOpen?.row && lhs.modelOpen?.line == rhs.modelOpen?.line && lhs.query == rhs.query
            && lhs.dragging?.row == rhs.dragging?.row && lhs.dragging?.line == rhs.dragging?.line
    }
}

/// The page: the Save bar pinned at the top, the rows scrolling under it, at most 1320 pt wide.
public struct RunsPageView: View {
    let page: RunsPage
    let actions: RunsPageActions
    let drawn: RunsPageDrawn?
    /// Bumped at each reorder, so a list the editor didn't take (a refused move) is drawn again from the page's order.
    @State private var reorders = 0

    public init(page: RunsPage, actions: RunsPageActions, drawn: RunsPageDrawn? = nil) {
        self.page = page
        self.actions = actions
        self.drawn = drawn
    }

    public var body: some View {
        let tokens = DesignTokens.RunsPage.self
        VStack(alignment: .leading, spacing: tokens.gap) {
            bar
                .frame(maxWidth: tokens.maxWidth)
                .padding(.top, tokens.top)
                .padding(.horizontal, tokens.sides)
            ScrollView {
                list
                    .frame(maxWidth: tokens.maxWidth)
                    .padding(.horizontal, tokens.sides)
                    .padding(.bottom, tokens.bottom)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var saveState: SaveBarState {
        switch page.save {
        case .editing: .editing
        case .saving: .saving
        case .saved: .saved
        case .refused(let reason): .refused(reason)
        }
    }

    private var bar: some View {
        SaveBar(changes: page.changeCount, state: saveState, onRevert: actions.revert, onSave: actions.save) {
            PopUp(
                RunsPage.scopeLabel,
                selection: Binding(get: { page.scope }, set: { actions.show($0) }),
                choices: page.scopes.map { PopUpChoice($0.scope, $0.title) },
                size: DesignTokens.RunsPage.control
            )
        }
    }

    private var list: some View {
        let tokens = DesignTokens.RunsPage.self
        let rows = page.rows
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if index > 0, !rows[index - 1].isDefault {
                    HairlineDivider()
                }
                RunsRowView(row: row, actions: actions, drawn: drawn, reordered: { reorders += 1 })
                    .id("\(row.id)-\(reorders)")
            }
        }
        .padding(tokens.listPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelSurface(in: PanelStyle.shape)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(SymphonyView.runs.title)
    }
}

/// One kind of run: its name and "Use Default's" on the left, its lines as a Reorderable list on the right, with Add a
/// Fallback under them and, with no fallback, the line saying a run waits.
struct RunsRowView: View {
    let row: RunsPage.Row
    let actions: RunsPageActions
    let drawn: RunsPageDrawn?
    /// Tells the page a list was reordered, so it draws the lists again from its order.
    var reordered: () -> Void = {}

    var body: some View {
        let tokens = DesignTokens.RunsPage.self
        let shape = RoundedRectangle(cornerRadius: tokens.defaultRadius, style: .continuous)
        HStack(alignment: .top, spacing: tokens.rowGap) {
            VStack(alignment: .leading, spacing: tokens.kindGap) {
                Text(row.title)
                    .textStyle(.rowTitle)
                    .foregroundStyle(DesignTokens.TextColor.primary.color)
                    .lineLimit(1)
                    .frame(minHeight: tokens.kindLineHeight)
                    .accessibilityAddTraits(.isHeader)
                if row.canUseDefaults {
                    Button(RunsPage.useDefaults) { actions.useDefaults(row.kind) }
                        .buttonStyle(DirectorButtonStyle(kind: .quiet, size: tokens.control))
                        .padding(.leading, tokens.useDefaultsInset)
                        .accessibilityLabel("\(RunsPage.useDefaults) for \(row.title)")
                }
            }
            .frame(width: tokens.kindWidth, alignment: .leading)
            ReorderableList(
                row.lines,
                onReorder: { order in
                    actions.reorder(row.kind, order)
                    reordered()
                },
                onRemove: { actions.remove(row.kind, $0) },
                removable: { place in row.lines.first { $0.id == place }?.removable ?? false },
                removeHelp: { RunsPage.Line.removeHelp($0 - 1) },
                addTitle: RunsPage.addFallback,
                onAdd: { actions.addFallback(row.kind) },
                footNote: row.waits.map { ReorderFootNote($0, status: .you) },
                drawn: drawnList
            ) { line in
                RunsLineView(row: row, line: line, actions: actions, drawn: drawn)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(tokens.rowPadding)
        .background { if row.isDefault { shape.fill(tokens.defaultFill.color) } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(row.title)
    }

    /// The still list of a story: the line it drags, or none.
    private var drawnList: ReorderableListDrawn? {
        guard let drawn else { return nil }
        guard let dragging = drawn.dragging, dragging.row == row.id else { return ReorderableListDrawn() }
        return ReorderableListDrawn(dragging: dragging.line + 1)
    }
}

/// A line's four pop-ups: Harness, Provider, Model (searchable, in the mono face) and Effort, each grey while its value
/// comes from Default.
struct RunsLineView: View {
    let row: RunsPage.Row
    let line: RunsPage.Line
    let actions: RunsPageActions
    let drawn: RunsPageDrawn?

    var body: some View {
        ForEach(line.fields, id: \.field) { field in
            control(field)
        }
    }

    @ViewBuilder
    private func control(_ field: RunsPage.Field) -> some View {
        let selection = Binding<String?>(get: { field.value }, set: { actions.pick(row.kind, line.id, field.field, $0) })
        let choices = field.choices.map { PopUpChoice($0.value, $0.title) }
        let spoken = "\(field.label), \(row.title) line \(line.id + 1)"
        if field.isSearchable {
            SearchablePopUp(
                field.label, selection: selection, choices: choices, noun: field.label.lowercased(), mono: true,
                inherited: !field.isOwn, drawnOpen: open
            )
            .accessibilityLabel(spoken)
        } else {
            PopUp(
                field.label, selection: selection, choices: choices, size: DesignTokens.RunsPage.control, accessibilityLabel: spoken,
                inherited: !field.isOwn
            )
        }
    }

    /// The Model list drawn open on this line, for a story.
    private var open: SearchablePopUp<String?>.DrawnOpen? {
        guard let drawn, let modelOpen = drawn.modelOpen, modelOpen.row == row.id, modelOpen.line == line.id else { return nil }
        let field = line.fields.first { $0.isSearchable }
        let shown = (field?.choices ?? []).filter { MenuSearch.matches($0.title, query: drawn.query) }
        return .init(query: drawn.query, highlighted: shown.count > 1 ? shown[1].value : nil)
    }
}
