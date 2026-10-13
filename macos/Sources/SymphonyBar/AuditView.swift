import AppKit
import SwiftUI
import SymphonyBarCore
import UniformTypeIdentifiers

// MARK: - The window model's Audit

extension SymphonyWindowModel {
    /// Symphony's today, the UTC day its audit files are named by.
    var auditToday: String { Audit.today(generatedAt: overviewState?.generatedAt) }

    /// Audit under its filters, the window's scope and Symphony's today; nil until the first read.
    var auditView: Audit? {
        auditRecords.map { records in
            Audit(
                records: records, verification: auditVerification, filter: auditFilter, scope: scope, today: auditToday,
                now: overviewState?.generatedAt ?? Date()
            )
        }
    }

    /// Opens Audit filtered to one ticket: the ticket page's Show Audit Records.
    func showAudit(ticket: String) {
        auditFilter = Audit.Filter(ticket: ticket)
        auditSelection = nil
        show(.audit)
        auditReadAt = nil
        readAuditIfDue()
    }

    /// Reads Audit's records under the filters the API applies, and the chain verification of their days, while
    /// Audit shows. Symphony answers both from its local audit files, with no Linear request.
    func readAuditIfDue() {
        guard selection == .audit, shownTicket == nil, !readingAudit, state.countsKnown,
            auditReadAt.map({ Date().timeIntervalSince($0) >= Self.ticketSlowInterval }) ?? true
        else { return }
        readingAudit = true
        let filter = auditFilter.query
        let scope = scope
        let today = auditToday
        Task {
            let records = await client.get(Audit.path(filter, scope: scope, today: today))
            let verification = await client.get(Audit.verifyPath(filter, today: today))
            // Filters changed while the reads were out: read again for them instead.
            let current = filter == auditFilter.query && scope == self.scope
            if current {
                if case let .loaded(data) = records {
                    auditRecords = AuditRecord.records(data)
                    auditResult = nil
                } else {
                    auditResult = records
                }
                if case let .loaded(data) = verification {
                    auditVerification = AuditVerification.decode(data)
                } else {
                    auditVerification = nil
                }
            }
            auditReadAt = current ? Date() : nil
            readingAudit = false
            if !current { readAuditIfDue() }
        }
    }

    /// The way out of Audit's empty state.
    func perform(_ action: Audit.Empty.Action) {
        switch action {
        case .clearFilters: auditFilter = Audit.Filter()
        case .showAllRepos: scope = .all
        }
    }

    /// Export…: a save panel, then every record under the filters and the search from the API's NDJSON export,
    /// one per line, as Symphony wrote them.
    func exportAudit() {
        guard !auditExporting else { return }
        let filter = auditFilter
        let scope = scope
        let today = auditToday
        let panel = NSSavePanel()
        panel.title = "Export Audit Records"
        panel.nameFieldStringValue = Audit.exportFileName(filter, today: today)
        panel.allowedContentTypes = [UTType(filenameExtension: "ndjson") ?? .json]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        auditExporting = true
        auditExportError = nil
        Task {
            let result = await client.download(Audit.exportPath(filter, scope: scope, today: today))
            auditExporting = false
            guard case let .loaded(data) = result else {
                auditExportError = Audit.exportError(result)
                return
            }
            do {
                try Audit.exportBody(Audit.exportLines(data, filter: filter, scope: scope, today: today)).write(to: url, options: .atomic)
            } catch {
                auditExportError = "Couldn't write \(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - D10: Audit

/// D10 for the window: the filters, each shown day's chain, the table and the inspector, or a placeholder.
struct AuditContent: View {
    @ObservedObject var model: SymphonyWindowModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        Group {
            if let audit = model.auditView {
                AuditView(
                    audit: audit,
                    filter: $model.auditFilter,
                    selection: $model.auditSelection,
                    inspectorShown: $model.inspectorShown,
                    today: model.auditToday,
                    exportError: model.auditExportError,
                    openTicket: model.openTicket,
                    perform: model.perform
                )
            } else if model.auditResult == .unsupported {
                EmptyState(title: EndpointPlaceholder.updateSymphony, symbol: EndpointPlaceholder.updateSymbol)
            } else {
                EmptyState(title: "Reading the audit records…", symbol: SymphonyView.audit.symbol, showsSpinner: true)
            }
        }
        .searchable(text: $model.auditFilter.search, placement: .toolbar, prompt: Audit.searchPrompt)
        .searchFocused($searchFocused)
        .onChange(of: model.auditSearchRequested, initial: true) { _, requested in
            guard requested else { return }
            searchFocused = true
            model.auditSearchRequested = false
        }
    }
}

struct AuditView: View {
    let audit: Audit
    @Binding var filter: Audit.Filter
    @Binding var selection: String?
    @Binding var inspectorShown: Bool
    let today: String
    var exportError: String?
    var openTicket: (String) -> Void = { _ in }
    var perform: (Audit.Empty.Action) -> Void = { _ in }
    @State private var sortOrder = [KeyPathComparator(\Audit.Row.timeSort, order: .reverse)]
    /// The table's own selection, handed to the model after the table's delegate call returns, as on Tickets.
    @State private var tableSelection: String?

    var body: some View {
        VStack(spacing: 0) {
            AuditHeader(audit: audit, filter: $filter, today: today, exportError: exportError)
            Divider()
            if let empty = audit.empty {
                EmptyState(
                    title: empty.title,
                    symbol: SymphonyView.audit.symbol,
                    actions: empty.action.map { action in [(action.title, { perform(action) })] } ?? []
                )
            } else {
                AuditTable(rows: audit.rows.sorted(using: sortOrder), selection: $tableSelection, sortOrder: $sortOrder, openTicket: openTicket)
                    .onKeyPress(.space) {
                        inspectorShown.toggle()
                        return .handled
                    }
            }
        }
        // Fill the detail from the top, as the other views do; otherwise the split view centres it.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { tableSelection = selection }
        .onChange(of: tableSelection) { _, chosen in
            guard chosen != selection else { return }
            Task { @MainActor in selection = chosen }
        }
        .onChange(of: selection) { _, chosen in
            if chosen != tableSelection { tableSelection = chosen }
        }
        .inspector(isPresented: $inspectorShown) {
            AuditInspector(row: audit.rows.first { $0.id == selection }, openTicket: openTicket)
                .inspectorColumnWidth(min: 260, ideal: 320, max: 480)
        }
    }
}

/// The filters and each shown day's chain, outside the table so they also render offscreen.
struct AuditHeader: View {
    let audit: Audit
    @Binding var filter: Audit.Filter
    let today: String
    var exportError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
            AuditFilterBar(audit: audit, filter: $filter, today: today)
            ForEach(audit.chain) { line in
                AuditChainLineView(line: line)
            }
            if let exportError {
                Label(exportError, systemImage: DesignTokens.Status.problem.symbol)
                    .font(DesignTokens.TypeStyle.callout.font)
                    .foregroundStyle(DesignTokens.Status.problem.tint)
            }
        }
        .padding(.horizontal, DesignTokens.Space.s4)
        .padding(.vertical, DesignTokens.Space.s2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// The kind and date pop-ups, the ticket a ticket page filtered to, and how many records show.
private struct AuditFilterBar: View {
    let audit: Audit
    @Binding var filter: Audit.Filter
    let today: String

    var body: some View {
        HStack(spacing: DesignTokens.Space.s3) {
            Picker("Kind", selection: $filter.kind) {
                Text("All kinds").tag(String?.none)
                Divider()
                ForEach(audit.kinds) { Text($0.title).tag(String?.some($0.id)) }
            }
            .pickerStyle(.menu)
            .fixedSize()
            Picker("Date", selection: $filter.date) {
                Text(Audit.title(.recent, today: today)).tag(Audit.DateFilter.recent)
                Divider()
                ForEach(audit.days, id: \.self) { Text(Audit.title(.day($0), today: today)).tag(Audit.DateFilter.day($0)) }
            }
            .pickerStyle(.menu)
            .fixedSize()
            if let ticket = filter.ticket {
                Button {
                    filter.ticket = nil
                } label: {
                    Label("Ticket \(ticket)", systemImage: "xmark.circle.fill")
                }
                .buttonStyle(.bordered)
                .help("Show every ticket's records")
                .accessibilityLabel("Filtered to \(ticket). Remove the filter")
            }
            Spacer()
            Text(audit.countText)
                .font(DesignTokens.TypeStyle.callout.font)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}

/// A day's verification: a seal and words, never color alone.
struct AuditChainLineView: View {
    let line: Audit.ChainLine

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.s2) {
            Image(systemName: line.symbol)
                .foregroundStyle(line.verified ? DesignTokens.Status.done.tint : DesignTokens.Status.problem.tint)
                .accessibilityHidden(true)
            Text(line.day).font(DesignTokens.TypeStyle.callout.font.weight(.semibold))
            Text(line.text)
                .font(DesignTokens.TypeStyle.callout.font)
                .foregroundStyle(line.verified ? .secondary : .primary)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(line.accessibilityLabel)
    }
}

/// C19: time, kind, ticket, repo, actor and summary; a row's record shows in the inspector, and Return or a
/// double-click opens its ticket.
struct AuditTable: View {
    let rows: [Audit.Row]
    @Binding var selection: String?
    @Binding var sortOrder: [KeyPathComparator<Audit.Row>]
    var openTicket: (String) -> Void

    var body: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Time", value: \.timeSort) { row in
                Text(row.timeText).monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 120)
            TableColumn("Kind", value: \.kindTitle) { row in
                HStack(spacing: DesignTokens.Space.s1) {
                    if row.breaksChain {
                        Image(systemName: Audit.brokenSymbol)
                            .foregroundStyle(DesignTokens.Status.problem.tint)
                            .help("The chain breaks at this record")
                    }
                    Text(row.kindTitle)
                }
            }
            .width(min: 90, ideal: 120)
            TableColumn("Ticket", value: \.ticketText) { row in
                Text(row.ticketText).font(DesignTokens.TypeStyle.mono.font)
            }
            .width(min: 70, ideal: 90)
            TableColumn("Repo", value: \.repoText)
                .width(min: 60, ideal: 90)
            TableColumn("Actor", value: \.actor)
                .width(min: 50, ideal: 70)
            TableColumn("Summary", value: \.summary) { row in
                Text(row.summary).lineLimit(1)
            }
            .width(min: 160, ideal: 360)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first, let row = rows.first(where: { $0.id == id }) {
                if let identifier = row.record.issueIdentifier {
                    Button("Open \(identifier)") { openTicket(identifier) }
                }
                Button("Copy Record") { copy(row.record.line) }
            }
        } primaryAction: { ids in
            ids.first.flatMap { id in rows.first { $0.id == id }?.record.issueIdentifier }.map(openTicket)
        }
        .accessibilityLabel("Audit records")
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// The inspector: the selected record's facts and the whole record.
struct AuditInspector: View {
    let row: Audit.Row?
    var openTicket: (String) -> Void = { _ in }

    var body: some View {
        if let row {
            ScrollView {
                AuditInspectorBody(row: row, openTicket: openTicket)
            }
        } else {
            EmptyState(title: "Select a record.", symbol: "sidebar.right")
        }
    }
}

/// The inspector's facts and record, outside the scroll view so they also render offscreen.
struct AuditInspectorBody: View {
    let row: Audit.Row
    var openTicket: (String) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s4) {
            VStack(alignment: .leading, spacing: DesignTokens.Space.s1) {
                Text(row.kindTitle).font(DesignTokens.TypeStyle.rowTitle.font)
                if !row.summary.isEmpty {
                    Text(row.summary).font(DesignTokens.TypeStyle.body.font).fixedSize(horizontal: false, vertical: true)
                }
            }
            if row.breaksChain {
                Label("The day's chain breaks at this record.", systemImage: Audit.brokenSymbol)
                    .font(DesignTokens.TypeStyle.callout.font)
                    .foregroundStyle(DesignTokens.Status.problem.tint)
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: DesignTokens.Space.s3, verticalSpacing: DesignTokens.Space.s2) {
                ForEach(Array(row.facts.enumerated()), id: \.offset) { _, fact in
                    GridRow {
                        Text(fact.label).foregroundStyle(.secondary).gridColumnAlignment(.leading)
                        Text(fact.value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .font(DesignTokens.TypeStyle.callout.font)
            VStack(alignment: .leading, spacing: DesignTokens.Space.s1) {
                Text("Record").font(DesignTokens.TypeStyle.caption.font).foregroundStyle(.secondary)
                Text(row.record.prettyJSON)
                    .font(DesignTokens.TypeStyle.mono.font)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(DesignTokens.Space.s2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DesignTokens.Surface.separator.color.opacity(0.3), in: RoundedRectangle(cornerRadius: DesignTokens.Radius.mark))
            }
            if let identifier = row.record.issueIdentifier {
                Button("Open \(identifier)") { openTicket(identifier) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(DesignTokens.Space.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
