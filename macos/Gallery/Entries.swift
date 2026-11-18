// The gallery's entries: the things one can look at. An entry is a shared component ("Button") or a screen
// ("Ticket page"). A component shows every variation of it together, on one board: nobody picks one. A screen shows
// one variation at a time, alone and as wide as the stage; its variations are listed under it, by name.
//
// Each entry says two things, once, here:
//   - which variations are its own: the ones main.swift and the *Stories.swift files name with one of its prefixes;
//   - which source files it shows, so a change to one of them is a reason to look at the entry.
// `foundation` lists the files every entry is drawn with (the design's values, the shared styles): a change there is a
// reason to look at all of them. `SymphonyGallery --affected` answers from these lists; nobody guesses.
//
// `SymphonyGallery --check` fails when a variation belongs to no entry or to two, when an entry has none, when a
// file under Sources/SymphonyBarUI is shown by no entry and is not listed as foundation or as nothing to see (a new
// shared component brings its entry with it), and when the committed list of component variations
// (`Gallery/component-variations.txt`, which the counterpart check reads) differs from the gallery's stories.
import Foundation

struct GalleryEntry {
    enum Kind: String { case component, screen }

    let id: String
    let title: String
    let kind: Kind
    /// The beginnings of its variations' names.
    let prefixes: [String]
    /// What it shows: paths under `macos/Sources/`, each a file or the beginning of several files' names.
    let files: [String]
}

let galleryEntries: [GalleryEntry] = [
    // Shared components.
    GalleryEntry(
        id: "button", title: "Button", kind: .component, prefixes: ["button-"],
        files: ["SymphonyBarUI/InteractionStyles.swift"]),
    GalleryEntry(
        id: "icon-button", title: "Icon button", kind: .component, prefixes: ["icon-button-"],
        files: ["SymphonyBarUI/InteractionStyles.swift"]),
    GalleryEntry(
        id: "inline-refusal", title: "Inline refusal", kind: .component, prefixes: ["inline-refusal-"],
        files: ["SymphonyBarUI/InteractionStyles.swift"]),
    GalleryEntry(
        id: "card", title: "Card states", kind: .component, prefixes: ["style-card-"],
        files: ["SymphonyBarUI/InteractionStyles.swift"]),
    GalleryEntry(id: "badge", title: "Badge and count badge", kind: .component, prefixes: ["badge-", "count-badge-"], files: []),
    GalleryEntry(id: "status-dot", title: "Status dot", kind: .component, prefixes: ["status-dot-"], files: ["SymphonyBarUI/LayerPulse.swift"]),
    GalleryEntry(id: "keyboard-hint", title: "Keyboard hint", kind: .component, prefixes: ["keyboard-hint-"], files: []),
    GalleryEntry(id: "panel-chip", title: "Panel, zone title and chip", kind: .component, prefixes: ["component-"], files: []),
    GalleryEntry(
        id: "row", title: "Row, tree list and progress strip", kind: .component,
        prefixes: ["row-", "style-row-", "tree-home", "progress-strip-"],
        files: ["SymphonyBarUI/ListComponents.swift", "SymphonyBarUI/InteractionStyles.swift", "SymphonyBarUI/LayerPulse.swift"]),
    GalleryEntry(
        id: "segmented-control", title: "Segmented control", kind: .component, prefixes: ["segmented-control-"],
        files: ["SymphonyBarUI/DesignSystem/SegmentedControl.swift"]),
    GalleryEntry(
        id: "pop-up", title: "Pop-up", kind: .component, prefixes: ["pop-up-"],
        files: ["SymphonyBarUI/DesignSystem/MenuControls.swift", "SymphonyBarUI/DesignSystem/Menu.swift", "SymphonyBarUI/DesignSystem/MenuPresenter.swift"]),
    GalleryEntry(
        id: "menu-button", title: "Menu button and its menu", kind: .component, prefixes: ["menu-button-"],
        files: ["SymphonyBarUI/DesignSystem/MenuControls.swift", "SymphonyBarUI/DesignSystem/Menu.swift", "SymphonyBarUI/DesignSystem/MenuPresenter.swift"]),
    GalleryEntry(
        id: "text-field", title: "Text field", kind: .component, prefixes: ["text-field-"],
        files: ["SymphonyBarUI/DesignSystem/TextInputs.swift"]),
    GalleryEntry(
        id: "search-field", title: "Search field", kind: .component, prefixes: ["search-field-"],
        files: ["SymphonyBarUI/DesignSystem/TextInputs.swift"]),
    GalleryEntry(
        id: "text-area", title: "Text area", kind: .component, prefixes: ["text-area-"],
        files: ["SymphonyBarUI/DesignSystem/TextInputs.swift"]),
    GalleryEntry(
        id: "table", title: "Table", kind: .component, prefixes: ["table-header-and-row-"],
        files: ["SymphonyBarUI/DesignSystem/DataTable.swift"]),
    GalleryEntry(
        id: "key-value-list", title: "Key-value list", kind: .component, prefixes: ["key-value-list-"],
        files: ["SymphonyBarUI/DesignSystem/KeyValueList.swift"]),
    GalleryEntry(
        id: "hairline-divider", title: "Hairline divider", kind: .component, prefixes: ["hairline-divider-"],
        files: ["SymphonyBarUI/DesignSystem/HairlineDivider.swift"]),
    GalleryEntry(
        id: "priority-mark", title: "Priority mark", kind: .component, prefixes: ["priority-mark-"],
        files: ["SymphonyBarUI/DesignSystem/PriorityMark.swift"]),
    GalleryEntry(
        id: "searchable-pop-up", title: "Searchable pop-up", kind: .component, prefixes: ["searchable-pop-up-"],
        files: [
            "SymphonyBarUI/DesignSystem/SearchablePopUp.swift", "SymphonyBarUI/DesignSystem/MenuControls.swift", "SymphonyBarUI/DesignSystem/Menu.swift",
            "SymphonyBarUI/DesignSystem/MenuPresenter.swift",
        ]),
    GalleryEntry(
        id: "reorderable-list", title: "Reorderable list", kind: .component, prefixes: ["reorderable-list-"],
        files: ["SymphonyBarUI/DesignSystem/ReorderableList.swift", "SymphonyBarCore/ReorderModel.swift"]),
    GalleryEntry(
        id: "save-bar", title: "Save bar", kind: .component, prefixes: ["save-bar-"], files: ["SymphonyBarUI/DesignSystem/SaveBar.swift"]),
    GalleryEntry(
        id: "list-card", title: "List card", kind: .component, prefixes: ["list-card-"], files: ["SymphonyBarUI/DesignSystem/ListCard.swift"]),
    GalleryEntry(
        id: "progress-meter", title: "Progress meter", kind: .component, prefixes: ["progress-meter-"],
        files: ["SymphonyBarUI/DesignSystem/ProgressMeter.swift", "SymphonyBarCore/ProgressMeterReading.swift"]),
    GalleryEntry(
        id: "collapsible-card", title: "Collapsible card", kind: .component, prefixes: ["collapsible-card-"],
        files: ["SymphonyBarUI/DesignSystem/Collapsible.swift"]),
    GalleryEntry(
        id: "window-bar", title: "Window bar", kind: .component, prefixes: ["window-bar-"],
        files: [
            "SymphonyBarUI/DesignSystem/WindowBar.swift", "SymphonyBarUI/DesignSystem/Breadcrumb.swift", "SymphonyBar/WindowBarView.swift",
            "SymphonyBarCore/WindowBar.swift",
        ]),
    GalleryEntry(
        id: "control-bar", title: "Control bar", kind: .component, prefixes: ["control-bar-"],
        files: [
            "SymphonyBarUI/DesignSystem/ControlBar.swift", "SymphonyBarCore/PageControls.swift", "SymphonyBar/WindowBarView.swift",
            "SymphonyBar/InsightsView.swift", "SymphonyBar/ShippedView.swift", "SymphonyBar/TicketsView.swift", "SymphonyBar/AuditView.swift",
            "SymphonyBar/JournalView.swift",
        ]),
    GalleryEntry(
        id: "sidebar", title: "Sidebar", kind: .component, prefixes: ["sidebar-"],
        files: ["SymphonyBarUI/DesignSystem/Sidebar.swift", "SymphonyBar/SymphonyWindowView.swift", "SymphonyBarCore/SymphonyWindow.swift"]),
    GalleryEntry(
        id: "status-line", title: "Status line", kind: .component, prefixes: ["status-line-"],
        files: [
            "SymphonyBarUI/DesignSystem/StatusLine.swift", "SymphonyBarUI/DesignSystem/WindowBar.swift", "SymphonyBar/HomeInboxView.swift",
            "SymphonyBarCore/HealthLine.swift", "SymphonyBarCore/Dispatch.swift",
        ]),
    GalleryEntry(
        id: "breadcrumb", title: "Breadcrumb", kind: .component, prefixes: ["breadcrumb-"],
        files: ["SymphonyBarUI/DesignSystem/Breadcrumb.swift", "SymphonyBarCore/WindowBar.swift"]),
    GalleryEntry(
        id: "mention-chips", title: "Mention chips and their popovers", kind: .component,
        prefixes: ["ticket-popover", "pr-popover", "missing-popover", "plan-chips", "pr-chips", "clarify-chips", "blocked-chips", "decision-chips-"],
        files: ["SymphonyBarUI/Chip", "SymphonyBarUI/ReferencePopoverView.swift", "SymphonyBarCore/Mention"]),
    GalleryEntry(
        id: "situation-line", title: "Situation line", kind: .component,
        prefixes: ["situation-line-", "style-situation-", "situations-"],
        files: ["SymphonyBar/SituationLine.swift", "SymphonyBarCore/Situation"]),
    GalleryEntry(
        id: "question", title: "Question, its options and the decision sheet", kind: .component,
        prefixes: ["question-option-", "question-block-", "decision-sheet-", "decision-context", "inbox-write-in"],
        files: ["SymphonyBarUI/QuestionBlock.swift", "SymphonyBarUI/SheetCover.swift", "SymphonyBarCore/Decision"]),
    GalleryEntry(
        id: "run-group", title: "Run group and its steps", kind: .component, prefixes: ["run-group-"],
        files: ["SymphonyBarUI/RunGroup.swift", "SymphonyBarUI/StepList.swift", "SymphonyBarUI/LayerPulse.swift", "SymphonyBarCore/RunStep"]),
    GalleryEntry(
        id: "timeline", title: "Timeline", kind: .component, prefixes: ["timeline-", "session-reader"],
        files: [
            "SymphonyBarUI/TimelineSection.swift", "SymphonyBarUI/SessionReaderView.swift", "SymphonyBarUI/LiveDuration.swift",
            "SymphonyBarUI/RunGroup.swift", "SymphonyBar/TranscriptView.swift", "SymphonyBarCore/TicketEvents", "SymphonyBarCore/Timeline",
        ]),
    GalleryEntry(
        id: "lifecycle", title: "Lifecycle and phase path", kind: .component, prefixes: ["lifecycle-", "phase-path-"],
        files: ["SymphonyBarUI/LifecycleSection.swift", "SymphonyBar/PhasesSection.swift", "SymphonyBarCore/Lifecycle"]),
    GalleryEntry(
        id: "facts-rail", title: "Facts rail and its panels", kind: .component, prefixes: ["facts-rail-"],
        files: ["SymphonyBarUI/FactsRail", "SymphonyBarCore/FactsRail", "SymphonyBarCore/ContextCard", "SymphonyBarCore/PullRequestPanel"]),
    GalleryEntry(
        id: "action-rail", title: "Action rail, Move to… and Start now", kind: .component,
        prefixes: ["action-rail-", "move-sheet", "start-now-"],
        files: ["SymphonyBar/ActionRail.swift", "SymphonyBar/InboxMoveViews.swift", "SymphonyBarCore/TicketMoves", "SymphonyBarCore/TicketActionRail"]),
    // Screens.
    GalleryEntry(
        id: "ticket-page", title: "Ticket page", kind: .screen, prefixes: ["ticket-page-"],
        files: ["SymphonyBar/TicketPageView.swift", "SymphonyBarCore/TicketPage"]),
    GalleryEntry(
        id: "home", title: "Home", kind: .screen, prefixes: ["home-board", "home-questions"],
        files: ["SymphonyBar/HomeView.swift", "SymphonyBar/HomeInboxView.swift", "SymphonyBarCore/Home"]),
    GalleryEntry(
        id: "inbox", title: "Inbox, its reviews and the peek", kind: .screen,
        prefixes: ["inbox-drawer", "inbox-blocked-", "plan-questions", "plan-unapplied", "plan-unasked", "watcher-decision", "peek-"],
        files: ["SymphonyBar/InboxView.swift", "SymphonyBar/PeekView.swift", "SymphonyBar/PRWatchCardView.swift", "SymphonyBarCore/Inbox", "SymphonyBarCore/Peek"]),
    GalleryEntry(
        id: "initiatives", title: "Initiatives", kind: .screen, prefixes: ["initiative-story-"],
        files: ["SymphonyBar/InitiativesView.swift", "SymphonyBarCore/Initiative"]),
    GalleryEntry(
        id: "tickets", title: "Tickets", kind: .screen, prefixes: ["tickets-table-", "ticket-views-"],
        files: ["SymphonyBar/TicketsView.swift", "SymphonyBarCore/Tickets", "SymphonyBarCore/TicketView"]),
    GalleryEntry(
        id: "journal", title: "Journal", kind: .screen, prefixes: ["journal-"],
        files: ["SymphonyBar/JournalView.swift", "SymphonyBarUI/JournalSection.swift", "SymphonyBarCore/Journal"]),
    GalleryEntry(
        id: "insights", title: "Insights: Quality, Usage and Shipped", kind: .screen, prefixes: ["insights-"],
        files: [
            "SymphonyBar/InsightsView.swift", "SymphonyBar/QualityView.swift", "SymphonyBar/UsageView.swift", "SymphonyBar/ShippedView.swift",
            "SymphonyBarCore/Insights",
        ]),
    GalleryEntry(
        id: "pull-request", title: "Pull request page", kind: .screen, prefixes: ["pr-page"],
        files: ["SymphonyBar/PullRequestPageView.swift", "SymphonyBarCore/PullRequestPage"]),
    GalleryEntry(
        id: "setup", title: "Setup and Add Repo", kind: .screen, prefixes: ["setup-", "add-repo-"],
        files: ["SymphonyBar/SetupView.swift", "SymphonyBar/AddRepoView.swift", "SymphonyBar/WorkflowSetup", "SymphonyBarCore/Setup", "SymphonyBarCore/AddRepo"]),
    GalleryEntry(
        id: "github-updates", title: "GitHub updates and their setup", kind: .screen, prefixes: ["github-updates-", "github-setup-"],
        files: ["SymphonyBar/GitHubUpdates", "SymphonyBarCore/GitHubUpdates"]),
    GalleryEntry(
        id: "factory-health", title: "Factory health: Linear webhooks, dispatch shadow, reconcile", kind: .screen,
        prefixes: ["linear-webhooks-", "dispatch-shadow-", "reconcile-"],
        files: ["SymphonyBar/SetupView.swift", "SymphonyBarCore/LinearWebhook", "SymphonyBarCore/DispatchShadow", "SymphonyBarCore/Reconcile"]),
    GalleryEntry(
        id: "repos", title: "Repos: pausing one", kind: .screen, prefixes: ["repo-pause-"],
        files: ["SymphonyBar/ReposView.swift", "SymphonyBar/SymphonyWindowView.swift", "SymphonyBarCore/RepoPause"]),
    GalleryEntry(
        id: "runs", title: "Factory › Runs", kind: .screen, prefixes: ["runs-page"],
        files: ["SymphonyBarUI/RunsPageView.swift", "SymphonyBar/RunsPageContent.swift", "SymphonyBarCore/RunsPage.swift"]),
]

/// The files every entry is drawn with: a change to one is a reason to look at all of them.
let galleryFoundation = ["SymphonyBarCore/DesignTokens.swift", "SymphonyBarUI/DesignSystem.swift", "SymphonyBar/SharedUI.swift"]

/// Files under `Sources/SymphonyBarUI` that draw nothing.
let galleryNothingToSee = ["SymphonyBarUI/NSWorkspace+FileLocation.swift"]

extension GalleryEntry {
    /// Whether `path` (under `macos/Sources/`) is one of the files it shows.
    func shows(_ path: String) -> Bool { files.contains { path == $0 || path.hasPrefix($0) } }

    func owns(_ variation: String) -> Bool { prefixes.contains { variation == $0 || variation.hasPrefix($0) } }
}

/// The entries a change to `paths` (repository paths) is a reason to look at: every one when a foundation file
/// changed.
func galleryAffected(by paths: [String]) -> (all: Bool, entries: [String]) {
    let sources = paths.compactMap { path -> String? in
        guard let range = path.range(of: "macos/Sources/") else { return nil }
        return String(path[range.upperBound...])
    }
    if sources.contains(where: { galleryFoundation.contains($0) }) { return (true, galleryEntries.map(\.id)) }
    return (false, galleryEntries.filter { entry in sources.contains(where: entry.shows) }.map(\.id))
}

/// What is wrong with the lists above, in plain words; empty when nothing is.
func galleryProblems(variations: [String], sharedFiles: [String]) -> [String] {
    var problems: [String] = []
    for variation in variations {
        let owners = galleryEntries.filter { $0.owns(variation) }.map(\.id)
        if owners.isEmpty { problems.append("The variation \(variation) belongs to no entry: add its prefix to one in Gallery/Entries.swift.") }
        if owners.count > 1 { problems.append("The variation \(variation) belongs to \(owners.joined(separator: " and ")): one entry must own it.") }
    }
    for entry in galleryEntries where !variations.contains(where: entry.owns) {
        problems.append("The entry \(entry.id) has no variation.")
    }
    for file in sharedFiles {
        let path = "SymphonyBarUI/" + file
        if !galleryEntries.contains(where: { $0.shows(path) }), !galleryFoundation.contains(path), !galleryNothingToSee.contains(path) {
            problems.append("\(path) is shown by no entry: give it one in Gallery/Entries.swift, with its variations, or list it as foundation or as nothing to see.")
        }
    }
    return problems
}

/// Where the committed list of component variations is, under `macos/`, and what heads it.
let componentVariationsFile = "Gallery/component-variations.txt"
let componentVariationsHeader = """
    # The Component Gallery's component variations, one per line, sorted: every `ComponentStory` the gallery draws, named
    # `<component>-<story>` (macos/Gallery/*Stories.swift). `SymphonyGallery --check` fails when this list and the
    # gallery's stories differ; `SymphonyGallery --component-variations > Gallery/component-variations.txt` writes it. The
    # counterpart check (CatalogCounterpartsTests, docs/design/catalog-counterparts.md) reads it.
    """

/// The file's whole text for `variations`: the header, then each name on its own line, sorted.
func componentVariationsText(_ variations: [String]) -> String {
    componentVariationsHeader + "\n" + Set(variations).sorted().joined(separator: "\n") + "\n"
}

/// What differs between the gallery's component variations and the committed list's text, in plain words; empty
/// when they agree.
func componentVariationProblems(variations: [String], committed: String?) -> [String] {
    let fix = "run `SymphonyGallery --component-variations > \(componentVariationsFile)` from macos/"
    guard let committed else { return ["\(componentVariationsFile) is missing: \(fix)."] }
    let listed = Set(committed.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") })
    let drawn = Set(variations)
    var problems: [String] = []
    for name in drawn.subtracting(listed).sorted() {
        problems.append("The gallery draws \(name), which \(componentVariationsFile) does not list: \(fix).")
    }
    for name in listed.subtracting(drawn).sorted() {
        problems.append("\(componentVariationsFile) lists \(name), which the gallery does not draw: \(fix).")
    }
    return problems
}
