# The catalog's Swift counterparts

What the design catalog draws (`docs/design/catalog/stories.js`) and what draws it in the app: each component and
section of the catalog, by its address (`components/key-value-list`, as in `#components/key-value-list/…`), and its
shared type in `SymphonyBarUI`, or why it has none yet. This is the list to read to see what is still to build
(`design-system.md` §5.4). The catalog's tokens are held to `DesignTokens` apart, by `DesignTokensCatalogTests`.

A line says one of three things:

- **A Swift type** in backticks: the shared component that draws the entry. The type is public in `SymphonyBarUI`,
  and every story of the entry has a variation of the same name in the Component Gallery (`macos/Gallery/`):
  the story "Header hover" of `components/collapsible-card` is the variation `collapsible-card-header-hover`.
- **not built**: nothing draws it yet. The ticket that builds it replaces the words with its type.
- **A reason**, in words: something draws it, but not yet as the shared component the catalog describes (it is
  private to a page, lives in the app's own target, or its stories are not in the gallery yet).

The counterpart check (`macos/Tests/SymphonyBarCoreTests/CatalogCounterpartsTests.swift`) reads the catalog, this
table and the gallery's list of component variations (`macos/Gallery/component-variations.txt`, which
`SymphonyGallery --check` holds to the gallery's stories). It fails when a catalog entry is missing from the table or
listed twice, when the table names an entry the catalog no longer has, when a mapped type does not exist, and when a
story of a mapped entry has no variation of its name, naming the story.

## Components

| Catalog entry | In SymphonyBarUI |
| --- | --- |
| `components/button` | `DirectorButtonStyle` |
| `components/icon-button` | `IconButton` |
| `components/menu-button` | `MenuButton` |
| `components/segmented-control` | `SegmentedControl` |
| `components/chip` | `Chip` draws its kinds; its hover, pressed, selected, focused, removable and disabled stories are not built |
| `components/badge` | `Badge` |
| `components/count-badge` | `CountBadge` |
| `components/status-dot` | `StatusDot` |
| `components/situation-line` | Drawn by the app's own `SituationLine`, not shared yet |
| `components/progress-meter` | `ProgressMeter` |
| `components/stacked-stage-bar` | not built |
| `components/text-field` | `DirectorTextField` |
| `components/search-field` | `SearchField` |
| `components/pop-up` | `PopUp` |
| `components/toggle` | not built |
| `components/tooltip` | not built |
| `components/row` | `Row` |
| `components/table-header-and-row` | `DataTable` |
| `components/card` | `Card` and `CardFace` draw it; its stories are not in the gallery one by one yet |
| `components/collapsible-card` | `CollapsibleCard` |
| `components/key-value-list` | `KeyValueList` |
| `components/timeline-entry` | Drawn inside `TimelineSection`, not shared on its own yet |
| `components/run-group` | `RunGroup` draws it; its stories are not in the gallery one by one yet |
| `components/step-strip` | not built |
| `components/phase-path` | `PhasePath` draws it; its stories are not in the gallery one by one yet |
| `components/step-list` | `StepList` draws it; its stories are not in the gallery one by one yet |
| `components/option-card` | Drawn inside `QuestionBlock`, not shared on its own yet |
| `components/answer-in-my-own-words` | Drawn by `TextArea` inside `QuestionBlock`, not shared on its own yet |
| `components/attachment-thumbnail` | not built |
| `components/empty-state` | not built |
| `components/toast` | not built |
| `components/sheet-header` | not built |
| `components/inline-refusal` | `Refusal` |
| `components/keyboard-hint` | `KeyboardHint` |
| `components/searchable-pop-up` | `SearchablePopUp` |
| `components/reorderable-list` | `ReorderableList` |
| `components/save-bar` | `SaveBar` |
| `components/list-card` | `ListCard` |

## Sections

A section is a part of a page. The page tickets compose it from the shared components above; until then it is drawn
by the page's own views.

| Catalog entry | In SymphonyBarUI |
| --- | --- |
| `sections/page-layout` | Drawn by the app's `TicketPageView` and Home, waiting on the page tickets |
| `sections/page-header` | Drawn by the app's `TicketPageView`, waiting on the ticket page tickets |
| `sections/action-rail` | Drawn by the app's own `ActionRail`, waiting on the ticket page tickets |
| `sections/lifecycle` | `LifecycleSection` draws it; its stories are not in the gallery one by one yet |
| `sections/facts-rail` | The facts rail's panels draw it; its stories are not in the gallery one by one yet |
| `sections/timeline` | `TimelineSection` draws it; its stories are not in the gallery one by one yet |
| `sections/question-block` | `QuestionBlock` draws it; its stories are not in the gallery one by one yet |
| `sections/decision-sheet` | `DecisionSheet` draws it; its stories are not in the gallery one by one yet |
| `sections/board-group` | Drawn by the app's Home, waiting on the Home ticket |
| `sections/table-with-filters` | Drawn by the app's Tickets page, waiting on the Tickets ticket |
| `sections/control-bar` | Drawn by the app's Tickets page, waiting on the Tickets ticket |
| `sections/window` | Its bar is `WindowBar` with its `Breadcrumb` (TP-1496); the rest is drawn by the app's `SymphonyWindowView`, its stories not in the gallery one by one yet |
