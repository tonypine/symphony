# Worked example: a plan ticket and what it produces

A filled [Plan](../plan.md) ticket with every artifact checked, and the artifacts Symphony's plan
run hands over for review. The domain is neutral on purpose (looking after house plants); swap in
your own. The stages, their rubrics and the review are in the `plan_pipeline` playbook partial
(`priv/playbook/plan_pipeline.liquid`), and the platform baseline in the
[house standards](../../standards/house-standards.md).

## The ticket

- **Title:** Plant care app for Android
- **Label:** `plan`

```md
## Vision

People who own a few house plants keep killing them by forgetting to water, or by watering too
much. I want an app that makes looking after plants feel easy, not like a chore.

## Context

Owners of 3 to 30 indoor plants, mostly beginners, some keen hobbyists. Android phones first.
Plants differ a lot: a cactus wants water every few weeks, a fern every few days, and both change
with the season.

## Constraints

- Android only for now, Kotlin and Jetpack Compose.
- Works fully offline; no account needed to start.
- No paid plant-identification service in the first release.

## Quality bar

Feels like a polished Material 3 app from day one. A beginner sets up their first plant in under a
minute.

## Artifacts wanted

- [x] Domain brief
- [x] User journeys
- [x] Kano feature map
- [x] Screens
- [x] Decisions

## Done when

A beginner can add their plants, gets reminded at the right time for each, and can see that their
plants are doing better after a month.
```

## What the plan run produces

One run produces every checked stage in order, then the sub-tickets, then hands over once. Each
stage is a Linear document in the ticket's project, attached to the ticket and titled
`<identifier> · <stage>`. Abridged contents:

### 1. Domain brief

- **People:** beginners who were given a plant; hobbyists with a shelf of them; someone
  plant-sitting for a friend.
- **Glossary:** watering interval, dormancy, repotting, light level (low, medium, bright indirect,
  direct), overwatering, root rot.
- **Constraints:** needs change with the season and the room; the same species varies by pot and
  soil; reminders that fire too often get ignored.
- **Sources:** extension-service care guides, the species care sheets the app will ship with, three
  interviews or forum threads summarised.

### 2. User journeys

- **Personas and jobs:** Sam (beginner) hires the app to stop killing plants; Ana (hobbyist) to
  track 25 plants without a spreadsheet; Lee (plant-sitter) to follow someone else's routine for a
  week.
- **Journeys:** J1 first launch and adding a first plant; J2 a reminder fires and the plant is
  watered; J3 fixing a mistake (watered the wrong plant, wrong date); J4 finding a plant and its
  history; J5 adjusting a schedule for winter; J6 sharing a routine with a plant-sitter; J7 moving
  to a new phone.

### 3. Kano feature map

| Feature | Class | Journeys | Why |
| --- | --- | --- | --- |
| Add a plant with a care schedule | Must-be | J1 | Nothing works without it. |
| Watering reminders | Performance | J2, J5 | Better timing means healthier plants. |
| Log a watering in one tap | Must-be | J2 | The core loop. |
| Seasonal schedule adjustment | Attractive | J5 | Delights keen owners; beginners don't expect it. |
| Share a routine | Attractive | J6 | Nice to have. |
| Edit and delete a plant or a log entry | Must-be (baseline) | J3 | House standards. |
| Undo the last action | Must-be (baseline) | J3 | House standards. |
| Search plants and history | Must-be (baseline) | J4 | House standards. |
| Backup, export and restore | Must-be (baseline) | J7 | House standards. |
| Settings | Must-be (baseline) | J5 | House standards. |
| Accessibility | Must-be (baseline) | all | House standards. |
| Offline use | Must-be (baseline) | all | House standards and the ticket's constraints. |
| Notification control | Must-be (baseline) | J2 | House standards. |
| Privacy controls | Must-be (baseline) | J7 | House standards. |
| Plant photo diary | Indifferent | J4 | Few users asked; no ticket. |

### 4. Screens

- **Screens document:** opens with a link to the HTML file, then each journey screen by screen.
  For example, J1: S1 Welcome (one screen, no sign-in), S2 Add plant (name, species, room, light;
  states: empty, species suggestions, validation error), S3 Plant list (states: empty with one call
  to action, filled, offline banner). Each screen names its Material 3 components: top app bar,
  navigation bar, extended floating action button, snackbar with Undo.
- **HTML screens file:** one `plant-care-screens.html` with every screen of the document in a
  phone frame, labelled `J1 · S2 Add plant`, styled in Material 3 with inline CSS and SVG icons and
  no external assets. It is attached to the ticket and linked at the top of the Screens document.

### 5. Decisions

- **D1. Where care data comes from.** Options: bundle a care sheet for 200 common species; ask the
  user for each plant; a paid identification service. Recommendation: bundle the sheets and let
  the user adjust, since the ticket rules out paid services and must work offline.
- **D2. Backup format.** Options: JSON file; CSV; Android auto backup only. Recommendation: a JSON
  file the user saves anywhere, plus Android auto backup, so J7 works without an account.

### 6. Implementation plan

`Backlog` sub-tickets, Must-be first, each naming its feature, journeys, screens and Kano class and
carrying a `## User walkthrough`:

1. `Add a plant and see it in the list`: Add a plant (Must-be), J1, S1 to S3.
2. `Log a watering, with undo`: Log a watering and Undo (Must-be), J2 and J3, S4.
3. `Edit and delete plants and log entries`: Edit and delete (Must-be), J3, S5 and S6.
4. `Search plants and history`: Search (Must-be), J4, S7.
5. `Back up, export and restore`: Backup (Must-be), J7, S8.
6. `Settings, notification control and privacy`: Settings, notification control, privacy controls
   (Must-be), J5 and J7, S9.
7. `Watering reminders`: Reminders (Performance), J2, S10.
8. `Seasonal schedules`: Seasonal adjustment (Attractive), J5, S11.
9. `Share a routine with a plant-sitter`: Share (Attractive), J6, S12.
10. `Final verification: Plant care app for Android`, blocked by every sub-ticket above.

Accessibility and offline use are Must-be across every screen, so each sub-ticket carries them in
its acceptance criteria instead of a ticket of their own.

## The review

The ticket moves to `In Review` with one review brief that links the five documents and the HTML
screens, lists the ten sub-tickets and asks for D1 and D2 under `Decisions needed`, each with its
recommended default (the run went on with it). The ticket's summary block links the same
documents, the HTML screens and the sub-tickets.

- **Approve:** move the ticket to `Waiting on sub-tickets`; Symphony promotes the sub-tickets.
- **Change:** comment on any part, for example "Drop the plant-sitter journey". The revision run
  removes J6 from the journeys, drops `Share a routine` from the Kano map, removes S12 from the
  Screens document and the HTML file, cancels sub-ticket 9 with the reason, updates the
  `Final verification:` checklist and the brief, and hands over again.
- **Reject:** move the ticket to `Rework`; Symphony cancels the `Backlog` sub-tickets and plans
  again.
