// The catalog's Text field and Search field stories (TP-1509), and the multi-line input of its Answer in my own words
// and the ticket page's composer as the Text area, each drawn by the shared components under the id the catalog gives
// the story (`docs/design/catalog/stories.js`). Each story is a variation of its own (`text-field-empty`), so the
// gallery's board shows them together under their names. The resting stories are live: in the gallery they can be
// typed in, hovered and focused; the hover, focus and error ones are drawn in that state.
import SwiftUI
import SymphonyBarCore
import SymphonyBarUI

/// A live story's text, kept while the gallery shows it.
private struct LiveText<Content: View>: View {
    @State var text: String
    let content: (Binding<String>) -> Content

    var body: some View { content($text) }
}

/// The catalog's Text field story: Reason, its placeholder Deploy freeze and its help, in a shown state.
@MainActor
func textFieldStory(
    value: String = "", state: DesignTokens.Field.State? = nil, error: String? = nil, reason: String? = nil
) -> AnyView {
    let help = "Shown to everyone who sees the pause."
    let field = LiveText(text: value) { text in
        DirectorTextField("Reason", text: text, placeholder: "Deploy freeze", help: help, error: error, disabledReason: reason, drawnAs: state)
    }
    return AnyView(field.frame(width: fieldStoryWidth))
}

/// The catalog's Search field story: Search tickets, in a shown state, with a query and what it found.
@MainActor
func searchFieldStory(query: String = "", matches: Int = 12, state: DesignTokens.Field.State? = nil) -> AnyView {
    let field = LiveText(text: query) { text in
        SearchField(
            "Search tickets", text: text, matches: matches, searched: "Search looks at identifiers and titles.", drawnAs: state
        )
    }
    return AnyView(field.frame(width: searchStoryWidth))
}

/// The own-words field's text area: empty with its placeholder, with words, and at its maximum, where it scrolls.
@MainActor
func textAreaStory(_ text: String = "", state: DesignTokens.Field.State? = nil) -> AnyView {
    let area = LiveText(text: text) { text in
        TextArea(
            "Answer in my own words…", text: text, placeholder: "For example: keep TP-1383 waiting until the new colours land.",
            accented: true, drawnAs: state
        )
    }
    return AnyView(area.frame(width: areaStoryWidth))
}

/// The catalog's `.field` width, the search story's and the own-words field's.
let fieldStoryWidth: CGFloat = 300
let searchStoryWidth: CGFloat = 280
let areaStoryWidth: CGFloat = 420

/// Ten lines of words, past the area's eight.
let textAreaFullText = (1...10).map { "Line \($0): approve, but make the dark status tints a step stronger first." }.joined(separator: "\n")

/// Every story of the three entries, in the catalog's order.
@MainActor
let fieldStories: [ComponentStory] = {
    func textField(_ id: String, height: CGFloat = 80, _ draw: @escaping @MainActor () -> AnyView) -> ComponentStory {
        ComponentStory(component: "text-field", id: id, title: "Text field", width: fieldStoryWidth, height: height, draw: draw)
    }
    func searchField(_ id: String, height: CGFloat = 40, _ draw: @escaping @MainActor () -> AnyView) -> ComponentStory {
        ComponentStory(component: "search-field", id: id, title: "Search field", width: searchStoryWidth, height: height, draw: draw)
    }
    func textArea(_ id: String, height: CGFloat = 100, _ draw: @escaping @MainActor () -> AnyView) -> ComponentStory {
        ComponentStory(component: "text-area", id: id, title: "Text area", width: areaStoryWidth, height: height, draw: draw)
    }
    return [
        textField("empty") { textFieldStory() },
        textField("filled") { textFieldStory(value: "Deploy freeze") },
        textField("hover") { textFieldStory(state: .hover) },
        textField("focused") { textFieldStory(value: "Deploy fr", state: .focused) },
        textField("error") { textFieldStory(state: .focused, error: "Give a reason so the pause explains itself.") },
        textField("disabled-with-reason") { textFieldStory(value: "Claude usage limit", reason: "The reason is set by the rule that paused it.") },
        searchField("empty") { searchFieldStory() },
        searchField("hover") { searchFieldStory(state: .hover) },
        searchField("focused") { searchFieldStory(state: .focused) },
        searchField("with-a-query") { searchFieldStory(query: "catalog", matches: 3) },
        searchField("no-results", height: 64) { searchFieldStory(query: "storybook", matches: 0) },
        textArea("empty") { textAreaStory() },
        textArea("with-text") { textAreaStory("Approve, but make the dark status tints a step stronger first.") },
        textArea("at-its-maximum", height: 180) { textAreaStory(textAreaFullText) },
    ]
}()
