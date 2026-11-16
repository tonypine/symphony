// The catalog's Segmented control, Pop-up and Menu button stories (TP-1508), each drawn by the shared components under
// the id the catalog gives the story (`docs/design/catalog/stories.js`). The snapshots write
// `<component>-<story>-<light|dark>.png`; the design sheet's three pages put each beside the catalog's story.
import SwiftUI
import SymphonyBarCore
import SymphonyBarUI

/// The catalog's Segmented control story: Day, Week, Month with Week picked, in a shown state.
@MainActor
func segmentedStory(
    _ titles: [String] = ["Day", "Week", "Month"], selected: Int = 1, size: DesignTokens.Control = .medium, hovered: Int? = nil,
    focused: Bool = false, reason: String? = nil
) -> AnyView {
    if let reason {
        return AnyView(
            SegmentedControl("Period", selection: .constant(selected), segments: titles.enumerated().map { Segment($0, $1) }, size: size, disabledReason: reason)
        )
    }
    return AnyView(SegmentedFace(titles: titles, selected: selected, size: size, hovered: hovered, focused: focused, reduceMotion: false).fixedSize())
}

/// The catalog's Pop-up story: Repo, All repos, its list All repos, symphony and web-shop.
let popUpRepos = ["All repos", "symphony", "web-shop"]

@MainActor
func popUpStory(value: String = "All repos", state: DesignTokens.Interaction = .rest, open: Bool = false, reason: String? = nil) -> AnyView {
    if let reason {
        return AnyView(
            PopUp("Repo", selection: .constant(value), choices: popUpRepos.map { PopUpChoice($0, $0) }, disabledReason: reason).fixedSize()
        )
    }
    let face = MenuControlFace(.popUp(label: "Repo", value: value), state: state, open: open, reduceMotion: false).fixedSize()
    guard open else { return AnyView(face) }
    return AnyView(
        VStack(alignment: .leading, spacing: DesignTokens.Menu.gap) {
            face
            MenuList(items: popUpRepos.map { MenuItem($0, checked: $0 == value) {} })
        }
    )
}

/// The catalog's Menu button story's menu: Todo, In Progress, Rework, a separator, Backlog with ⌘⌫, Canceled in red;
/// the catalog keeps the tick's room on every item.
let menuButtonItems: [MenuItem] = [
    MenuItem("Todo", checked: false) {}, MenuItem("In Progress", checked: false) {}, MenuItem("Rework", checked: false) {}, .separator,
    MenuItem("Backlog", shortcut: "⌘ ⌫", checked: false) {}, MenuItem("Canceled", checked: false, destructive: true) {},
]

@MainActor
func menuButtonStory(state: DesignTokens.Interaction = .rest, open: Bool = false, reason: String? = nil) -> AnyView {
    if let reason {
        return AnyView(MenuButton("Move to…", disabledReason: reason) { menuButtonItems }.fixedSize())
    }
    let face = MenuControlFace(.menu(title: "Move to…", glyph: nil), state: state, open: open, reduceMotion: false).fixedSize()
    guard open else { return AnyView(face) }
    return AnyView(
        VStack(alignment: .leading, spacing: DesignTokens.Menu.gap) {
            face
            MenuList(items: menuButtonItems, highlighted: 1)
        }
    )
}

/// Every story of the three entries, in the catalog's order.
@MainActor
let menuStories: [ComponentStory] = {
    func segmented(_ id: String, height: CGFloat = 40, _ draw: @escaping @MainActor () -> AnyView) -> ComponentStory {
        ComponentStory(component: "segmented-control", id: id, title: "Segmented control", width: 320, height: height, draw: draw)
    }
    func popUp(_ id: String, height: CGFloat = 40, _ draw: @escaping @MainActor () -> AnyView) -> ComponentStory {
        ComponentStory(component: "pop-up", id: id, title: "Pop-up", width: 320, height: height, draw: draw)
    }
    func menuButton(_ id: String, height: CGFloat = 40, _ draw: @escaping @MainActor () -> AnyView) -> ComponentStory {
        ComponentStory(component: "menu-button", id: id, title: "Menu button", width: 320, height: height, draw: draw)
    }
    return [
        segmented("default") { segmentedStory() },
        segmented("segment-hover") { segmentedStory(hovered: 2) },
        segmented("focused") { segmentedStory(focused: true) },
        segmented("two-segments") { segmentedStory(["Tokens", "Runs"], selected: 0) },
        segmented("small") { segmentedStory(size: .small) },
        segmented("large") { segmentedStory(size: .large) },
        segmented("disabled-with-reason", height: 64) { segmentedStory(reason: "The period is fixed while comparing two epics.") },
        popUp("default") { popUpStory() },
        popUp("hover") { popUpStory(state: .hover) },
        popUp("pressed") { popUpStory(state: .press) },
        popUp("open", height: 160) { popUpStory(open: true) },
        popUp("focused") { popUpStory(state: .focus) },
        popUp("disabled-with-reason", height: 64) { popUpStory(value: "symphony", reason: "Only one repo is set up.") },
        menuButton("closed") { menuButtonStory() },
        menuButton("hover") { menuButtonStory(state: .hover) },
        menuButton("pressed") { menuButtonStory(state: .press) },
        menuButton("open", height: 220) { menuButtonStory(open: true) },
        menuButton("focused") { menuButtonStory(state: .focus) },
        menuButton("disabled-with-reason", height: 64) { menuButtonStory(reason: "Moves wait while a run is working.") },
    ]
}()
