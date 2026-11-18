// The catalog's Searchable pop-up, Save bar, List card and Progress meter stories (TP-1530) and its Reorderable list
// stories (TP-1531), the components the Factory › Runs and Providers pages are built from, each drawn by the shared
// component under the id the catalog gives the story (`docs/design/catalog/stories.js`), each a variation of its own.
// The Closed searchable pop-up, the Changes not saved bar and the Resting reorderable list are live: in the gallery
// the pop-up opens, narrows as one types and picks, the bar's Revert and Save act, and the list's lines drag, move
// from the keyboard and are removed.
import SwiftUI
import SymphonyBarCore
import SymphonyBarUI

// MARK: - Searchable pop-up

/// The catalog's models of each provider (`MODELS`).
let galleryModels: [String: [String]] = [
    "anthropic": ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"],
    "opencode-go": ["kimi-k3", "hy4-flash", "hy4-flash-free", "deepseek-v4-pro", "beam-free"],
    "openrouter": ["deepseek/deepseek-flash", "deepseek/deepseek-v4-pro", "anthropic/claude-haiku-4.5", "openai/gpt-5"],
]

/// A live story's picked value, kept while the gallery shows it.
private struct LivePick: View {
    @State var value: String
    let models: [String]
    let inherited: Bool

    var body: some View {
        SearchablePopUp(
            "Model", selection: $value, choices: models.map { PopUpChoice($0, $0) }, noun: "model", mono: true, inherited: inherited
        )
    }
}

/// The catalog's Searchable pop-up story: Model, a provider's models, drawn open with what is typed and the choice
/// lit (the catalog lights the second one shown), or closed and live.
@MainActor
func searchablePopUpStory(
    provider: String = "anthropic", value: String = "claude-opus-5-5", open: Bool = false, query: String = "", inherited: Bool = false
) -> AnyView {
    let models = galleryModels[provider] ?? []
    guard open else { return AnyView(LivePick(value: value, models: models, inherited: inherited).fixedSize()) }
    let shown = models.filter { MenuSearch.matches($0, query: query) }
    let lit = shown.count > 1 ? shown[1] : nil
    return AnyView(
        SearchablePopUp(
            "Model", selection: .constant(value), choices: models.map { PopUpChoice($0, $0) }, noun: "model", mono: true, inherited: inherited,
            drawnOpen: .init(query: query, highlighted: lit)
        )
        .fixedSize()
    )
}

// MARK: - Reorderable list

/// One line of the catalog's Reorderable list story: a harness, a provider, a model and an effort.
struct GalleryRunStep: Identifiable, Equatable {
    let harness: String
    let provider: String
    let model: String
    let effort: String

    var id: String { "\(provider)/\(model)" }
}

/// The catalog's four steps (`steps` of the Reorderable list story), with the catalog's names (`NAMES`).
let galleryRunSteps = [
    GalleryRunStep(harness: "Claude", provider: "Anthropic", model: "claude-opus-5-5", effort: "medium"),
    GalleryRunStep(harness: "OpenCode", provider: "OpenCode Go", model: "kimi-k3", effort: ""),
    GalleryRunStep(harness: "Claude", provider: "OpenRouter", model: "deepseek/deepseek-flash", effort: "low"),
    GalleryRunStep(harness: "Claude", provider: "Anthropic", model: "claude-haiku-5-5", effort: "low"),
]

/// A line's controls as the catalog draws them: four small pop-ups, the model in the mono face; a line that can't
/// be used now carries the orange edge and says why.
@MainActor
@ViewBuilder
func galleryRunStepLine(_ step: GalleryRunStep, off: Bool = false) -> some View {
    galleryStepPop("Harness", step.harness, off: off)
    galleryStepPop("Provider", step.provider, off: off)
    SearchablePopUp("Model", selection: .constant(step.model), choices: [PopUpChoice(step.model, step.model)], noun: "model", mono: true)
        .reorderLineOff(off)
    galleryStepPop("Effort", step.effort, off: off)
    if off { ReorderLineNote("\(step.provider) is paused") }
}

/// A small pop-up of a line, showing `value` ("None" when empty).
@MainActor
private func galleryStepPop(_ label: String, _ value: String, off: Bool) -> some View {
    PopUp(label, selection: .constant(value), choices: [PopUpChoice(value, value.isEmpty ? "None" : value)], size: .small).reorderLineOff(off)
}

/// The live list: drag a line by its handle, or Space, the arrows and Space (Escape puts it back); remove a line;
/// Add a Fallback brings back the first step not in the list.
private struct LiveReorderableList: View {
    @State var steps: [GalleryRunStep]
    let removable: Bool

    var body: some View {
        ReorderableList(
            steps,
            onReorder: { order in steps = order.compactMap { id in steps.first { $0.id == id } } },
            onRemove: removable ? { id in steps.removeAll { $0.id == id } } : nil,
            addTitle: "Add a Fallback",
            onAdd: {
                if let next = galleryRunSteps.first(where: { step in !steps.contains(step) }) { steps.append(next) }
            }
        ) { step in
            galleryRunStepLine(step)
        }
    }
}

/// The catalog's Reorderable list story: `count` of its steps, 760 pt, 24 pt above and below, the Add a Fallback
/// button under them; live, or in a still state (`drawn`) with the line at `off` unusable now.
@MainActor
func reorderableListStory(count: Int = 3, drawn: ReorderableListDrawn? = nil, off: Int? = nil, removable: Bool = true) -> AnyView {
    let steps = Array(galleryRunSteps.prefix(max(1, count)))
    let list: AnyView
    if drawn == nil, off == nil {
        list = AnyView(LiveReorderableList(steps: steps, removable: removable))
    } else {
        list = AnyView(
            ReorderableList(
                steps, onReorder: { _ in }, onRemove: removable ? { _ in } : nil, addTitle: "Add a Fallback", onAdd: {}, drawn: drawn ?? .init()
            ) { step in
                galleryRunStepLine(step, off: steps.firstIndex(of: step).map { $0 + 1 } == off)
            }
        )
    }
    return AnyView(list.padding(.vertical, reorderableListStoryPadding).frame(width: reorderableListStoryWidth, alignment: .leading))
}

let reorderableListStoryWidth: CGFloat = 760
let reorderableListStoryPadding: CGFloat = 24

/// The story's height: its padding, the lines and their gaps, and the add button under them.
func reorderableListStoryHeight(_ count: Int) -> CGFloat {
    let list = DesignTokens.ReorderableList.self
    return 2 * reorderableListStoryPadding + CGFloat(count) * (list.lineHeight + list.gap) + list.control.height
}

// MARK: - Save bar

/// The catalog's For pop-up on the bar's left: All repositories.
@MainActor
private var saveBarScope: some View {
    PopUp("For", selection: .constant("All repositories"), choices: [PopUpChoice("All repositories", "All repositories")], size: .small)
}

/// The live bar: Revert takes the changes back, Save saves them.
private struct LiveSaveBar: View {
    @State var changes: Int
    @State var state: SaveBarState = .editing

    var body: some View {
        SaveBar(changes: changes, state: state, onRevert: { changes = 0 }, onSave: {
            changes = 0
            state = .saved
        }) { saveBarScope }
    }
}

/// The catalog's Save bar story: 900 pt, the For pop-up on its left (`scope`), in a shown state.
@MainActor
func saveBarStory(changes: Int = 2, state: SaveBarState = .editing, scope: Bool = true, live: Bool = false) -> AnyView {
    let bar: AnyView
    if live {
        bar = AnyView(LiveSaveBar(changes: changes))
    } else if scope {
        bar = AnyView(SaveBar(changes: changes, state: state, onRevert: {}, onSave: {}) { saveBarScope })
    } else {
        bar = AnyView(SaveBar(changes: changes, state: state, onRevert: {}, onSave: {}))
    }
    return AnyView(bar.frame(width: saveBarStoryWidth))
}

let saveBarStoryWidth: CGFloat = 900

// MARK: - List card

/// The catalog's List card story: Anthropic, 62 % of the week, 3 working, in a shown state.
@MainActor
func listCardStory(
    _ content: ListCardContent = ListCardContent(title: "Anthropic", fact: "62 % of the week", status: .done, statusLine: "3 working", live: true),
    state: DesignTokens.Interaction = .rest, windowFocused: Bool = true
) -> AnyView {
    AnyView(ListCardFace(content, state: state, windowFocused: windowFocused, reduceMotion: false).frame(width: listCardStoryWidth))
}

let listCardStoryWidth: CGFloat = 340

// MARK: - Progress meter

/// The catalog's Progress meter story: Tokens today, 2.1M of 5M, resetting at midnight.
@MainActor
func progressMeterStory(label: String = "Tokens today", used: Double = 2_100_000, cap: Double = 5_000_000, resets: String = "at midnight") -> AnyView {
    AnyView(ProgressMeter(ProgressMeterReading(label: label, used: used, cap: cap, unit: .tokens, resets: resets)))
}

/// The catalog's one-line story: Week, 640 pt, resetting Thu 19 Nov, 14:00, with a stop mark at `stop` %.
@MainActor
func progressLineStory(percent: Int, stop: Int? = nil) -> AnyView {
    AnyView(ProgressMeter(line: "Week", percent: percent, stop: stop, resets: "Thu 19 Nov, 14:00").frame(width: progressLineStoryWidth))
}

let progressLineStoryWidth: CGFloat = 640

/// Every story of the four entries, in the catalog's order.
@MainActor
let factoryStories: [ComponentStory] = {
    func picker(_ id: String, height: CGFloat = 40, _ draw: @escaping @MainActor () -> AnyView) -> ComponentStory {
        ComponentStory(component: "searchable-pop-up", id: id, title: "Searchable pop-up", width: 320, height: height, draw: draw)
    }
    func reorder(_ id: String, count: Int = 3, _ draw: @escaping @MainActor () -> AnyView) -> ComponentStory {
        ComponentStory(
            component: "reorderable-list", id: id, title: "Reorderable list", width: reorderableListStoryWidth,
            height: reorderableListStoryHeight(count), draw: draw)
    }
    func saveBar(_ id: String, _ draw: @escaping @MainActor () -> AnyView) -> ComponentStory {
        ComponentStory(component: "save-bar", id: id, title: "Save bar", width: saveBarStoryWidth, height: 48, draw: draw)
    }
    func listCard(_ id: String, _ draw: @escaping @MainActor () -> AnyView) -> ComponentStory {
        ComponentStory(component: "list-card", id: id, title: "List card", width: listCardStoryWidth, height: 72, draw: draw)
    }
    func meter(_ id: String, width: CGFloat = 320, height: CGFloat = 64, _ draw: @escaping @MainActor () -> AnyView) -> ComponentStory {
        ComponentStory(component: "progress-meter", id: id, title: "Progress meter", width: width, height: height, draw: draw)
    }
    let waiting = ListCardContent(title: "Anthropic", fact: "62 % of the week", status: .you, statusLine: "Paused by you · 12 min")
    let noFact = ListCardContent(title: "OpenAI", fact: "", status: .idle, statusLine: "Not in use")
    return [
        picker("closed") { searchablePopUpStory() },
        picker("open", height: 250) { searchablePopUpStory(open: true) },
        picker("finding", height: 250) {
            searchablePopUpStory(provider: "openrouter", value: "deepseek/deepseek-flash", open: true, query: "deep")
        },
        picker("nothing-matches", height: 250) { searchablePopUpStory(open: true, query: "gpt") },
        picker("value-from-a-default") { searchablePopUpStory(inherited: true) },
        reorder("resting") { reorderableListStory() },
        reorder("handle-hover") { reorderableListStory(drawn: .init(hover: 2)) },
        reorder("dragging") { reorderableListStory(drawn: .init(dragging: 3)) },
        reorder("handle-focused") { reorderableListStory(drawn: .init(focused: 2)) },
        reorder("a-line-that-can-t-be-used-now") { reorderableListStory(off: 1) },
        reorder("one-line", count: 1) { reorderableListStory(count: 1) },
        saveBar("nothing-changed") { saveBarStory(changes: 0) },
        saveBar("changes-not-saved") { saveBarStory(live: true) },
        saveBar("saving") { saveBarStory(state: .saving) },
        saveBar("saved") { saveBarStory(changes: 0, state: .saved) },
        saveBar("refused") { saveBarStory(state: .refused("runs.qa resolves no model; set one there or in Default")) },
        saveBar("no-scope") { saveBarStory(scope: false) },
        listCard("resting") { listCardStory() },
        listCard("hover") { listCardStory(state: .hover) },
        listCard("selected") { listCardStory(state: .selection) },
        listCard("selected-window-not-focused") { listCardStory(state: .selection, windowFocused: false) },
        listCard("focused") { listCardStory(state: .focus) },
        listCard("waiting-on-you") { listCardStory(waiting, state: .selection) },
        listCard("no-fact") { listCardStory(noFact) },
        meter("calm") { progressMeterStory() },
        meter("near-the-cap") { progressMeterStory(used: 4_100_000) },
        meter("at-the-cap") { progressMeterStory(used: 4_900_000) },
        meter("ticket-cap") {
            progressMeterStory(label: "TP-1382 against its cap", used: 7_600_000, cap: 8_000_000, resets: "never: the cap is per ticket")
        },
        meter("empty") { progressMeterStory(used: 0) },
        meter("one-line", width: progressLineStoryWidth, height: 32) { progressLineStory(percent: 62) },
        meter("one-line-with-a-stop-mark", width: progressLineStoryWidth, height: 32) { progressLineStory(percent: 62, stop: 90) },
        meter("one-line-at-the-stop-mark", width: progressLineStoryWidth, height: 32) { progressLineStory(percent: 90, stop: 90) },
        meter("one-line-at-the-cap", width: progressLineStoryWidth, height: 32) { progressLineStory(percent: 100, stop: 90) },
    ]
}()
