// The catalog's Button, Icon button and Inline refusal stories (TP-1505), each drawn by the shared components under
// the id the catalog gives the story (`docs/design/catalog/stories.js`: its name, lower-cased, with dashes). The
// snapshots write `<component>-<story>-<light|dark>.png`; the design sheet puts each beside the catalog's story.
import SwiftUI
import SymphonyBarCore
import SymphonyBarUI

/// One catalog story: its component's id in the catalog's address, its own id, and the view.
struct ComponentStory {
    /// `button`, `icon-button` or `inline-refusal`.
    let component: String
    let id: String
    /// The catalog's component title, for the sheet.
    let title: String
    /// What the stage is drawn at, as designed; the sheet draws the view at the catalog's measured size.
    let width: CGFloat
    let height: CGFloat
    let draw: @MainActor () -> AnyView
}

/// The catalog's glyph names as SF Symbols.
let catalogGlyphs = [
    "play": "play.fill", "stop": "stop.fill", "refresh": "arrow.clockwise", "pr": "arrow.triangle.pull", "plus": "plus",
    "undo": "arrow.uturn.backward", "inspector": "sidebar.right", "more": "ellipsis", "close": "xmark",
]

/// A button story: the face in a shown state, or the live button with its reason when it is disabled.
@MainActor
func buttonStory(
    _ label: String, kind: ButtonKind = .primary, size: DesignTokens.Control = .medium, glyph: String? = nil,
    state: DesignTokens.Interaction = .rest, reason: String? = nil
) -> AnyView {
    if let reason {
        return AnyView(Button(label) {}.directorButton(kind, size: size, glyph: glyph, disabledReason: reason))
    }
    return AnyView(ButtonFace(label: Text(label), kind: kind, size: size, glyph: glyph, state: state, reduceMotion: false))
}

/// Sizes side by side: each kind at the three sizes, then the icon button and the menu button.
@MainActor
func buttonSizesSideBySide() -> AnyView {
    let kinds: [(ButtonKind, String)] = [(.primary, "Primary"), (.secondary, "Secondary"), (.destructive, "Destructive"), (.quiet, "Quiet")]
    return AnyView(
        Grid(alignment: .leading, horizontalSpacing: DesignTokens.Space.s4, verticalSpacing: DesignTokens.Space.s3) {
            GridRow {
                Text("")
                ForEach(DesignTokens.Control.allCases, id: \.self) { size in
                    rowLabel("\(size.rawValue.capitalized) · \(Int(size.height)) pt")
                }
            }
            ForEach(Array(kinds.enumerated()), id: \.offset) { _, row in
                GridRow {
                    rowLabel(row.1)
                    ForEach(DesignTokens.Control.allCases, id: \.self) { size in
                        ButtonFace(label: Text("Approve"), kind: row.0, size: size, state: .rest, reduceMotion: false).fixedSize()
                    }
                }
            }
            GridRow {
                rowLabel("Icon button")
                ForEach(DesignTokens.Control.allCases, id: \.self) { size in
                    IconButtonFace("ellipsis", size: size, state: .rest, reduceMotion: false)
                }
            }
            GridRow {
                rowLabel("Menu button")
                ForEach(DesignTokens.Control.allCases, id: \.self) { size in
                    ButtonFace(
                        label: HStack(spacing: DesignTokens.Control.glyphGap) {
                            Text("Move to…")
                            Image(systemName: "chevron.down").font(size.glyphFont()).accessibilityHidden(true)
                        },
                        size: size, state: .rest, reduceMotion: false
                    )
                    .fixedSize()
                }
            }
        }
    )
}

/// A row or column name in the sizes grid, in the label style.
func rowLabel(_ text: String) -> some View {
    Text(text).textStyle(.label).foregroundStyle(DesignTokens.TextColor.secondary.color)
}

/// An icon button story: the face in a shown state, or the live icon button with its reason when it is disabled.
@MainActor
func iconButtonStory(size: DesignTokens.Control = .medium, state: DesignTokens.Interaction = .rest, on: Bool = false, reason: String? = nil) -> AnyView {
    let symbol = catalogGlyphs["inspector"]!
    if let reason {
        return AnyView(IconButton(symbol, help: "Show the details pane", size: size, disabledReason: reason) {})
    }
    return AnyView(IconButtonFace(symbol, size: size, on: on, state: state, reduceMotion: false))
}

let buttonReason = "Checks are still running on PR #812."

/// Every story of the three entries, in the catalog's order.
@MainActor
let componentStories: [ComponentStory] = {
    func button(_ id: String, width: CGFloat = 320, height: CGFloat = 40, _ draw: @escaping @MainActor () -> AnyView) -> ComponentStory {
        ComponentStory(component: "button", id: id, title: "Button", width: width, height: height, draw: draw)
    }
    func icon(_ id: String, height: CGFloat = 40, _ draw: @escaping @MainActor () -> AnyView) -> ComponentStory {
        ComponentStory(component: "icon-button", id: id, title: "Icon button", width: 240, height: height, draw: draw)
    }
    func refusal(_ id: String, _ draw: @escaping @MainActor () -> AnyView) -> ComponentStory {
        ComponentStory(component: "inline-refusal", id: id, title: "Inline refusal", width: 360, height: 64, draw: draw)
    }
    return [
        button("primary") { buttonStory("Approve Plan") },
        button("primary-hover") { buttonStory("Approve Plan", state: .hover) },
        button("primary-pressed") { buttonStory("Approve Plan", state: .press) },
        button("primary-focused") { buttonStory("Approve Plan", state: .focus) },
        button("primary-disabled-with-reason", height: 64) { buttonStory("Approve and Merge…", reason: buttonReason) },
        button("secondary") { buttonStory("Open Checks", kind: .secondary) },
        button("secondary-hover") { buttonStory("Open Checks", kind: .secondary, state: .hover) },
        button("secondary-pressed") { buttonStory("Open Checks", kind: .secondary, state: .press) },
        button("secondary-disabled-with-reason", height: 64) {
            buttonStory("Restart…", kind: .secondary, reason: "A run is still finishing. Wait for it, or stop it first.")
        },
        button("destructive") { buttonStory("Stop Run…", kind: .destructive) },
        button("destructive-hover") { buttonStory("Stop Run…", kind: .destructive, state: .hover) },
        button("destructive-in-a-sheet") { buttonStory("Stop Run", kind: .destructiveFilled) },
        button("quiet") { buttonStory("Show All", kind: .quiet) },
        button("quiet-hover") { buttonStory("Show All", kind: .quiet, state: .hover) },
        button("with-a-glyph") { buttonStory("Run Again", kind: .secondary, glyph: catalogGlyphs["refresh"]) },
        button("small") { buttonStory("Open", kind: .secondary, size: .small) },
        button("medium") { buttonStory("Open Checks", kind: .secondary) },
        button("large") { buttonStory("Send Decision…", size: .large) },
        button("sizes-side-by-side", width: 520, height: 300) { buttonSizesSideBySide() },
        icon("default") { iconButtonStory() },
        icon("hover") { iconButtonStory(state: .hover) },
        icon("pressed") { iconButtonStory(state: .press) },
        icon("focused") { iconButtonStory(state: .focus) },
        icon("on") { iconButtonStory(on: true) },
        icon("small") { iconButtonStory(size: .small) },
        icon("large") { iconButtonStory(size: .large) },
        icon("disabled-with-reason", height: 64) { iconButtonStory(reason: "No ticket is selected.") },
        refusal("under-a-button") { buttonStory("Approve and Merge…", reason: buttonReason) },
        refusal("standalone") { AnyView(Refusal(reason: "Moves wait while a run is working.")) },
        refusal("with-a-way-to-fix-it") {
            AnyView(
                VStack(alignment: .leading, spacing: DesignTokens.Control.glyphGap) {
                    ButtonFace(label: Text("Restart…"), kind: .primary, state: .off, reduceMotion: false)
                    Refusal(reason: "A run is still finishing.", fix: "Stop it") {}
                }
            )
        },
    ]
}()

/// A story on the window surface, as the catalog's canvas draws it.
@MainActor
func componentStorySnapshot(_ story: ComponentStory) -> some View {
    componentStage(story.draw(), width: story.width + 2 * DesignTokens.Space.s6)
}
