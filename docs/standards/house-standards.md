# House standards

The standards every plan ticket's product must meet, whatever its niche. The `plan_pipeline`
playbook partial (`priv/playbook/plan_pipeline.liquid`) loads this file on every plan run that
produces a Kano feature map or screens ([ADR 0001](../adr/0001-director-workflow.md)).

A project overrides this file with a Linear document named **House standards**. Link it from the
plan ticket's description (or quote it there): the run follows it instead of this file and says so
in the Kano map.

## Platform baseline

Users expect these of every app, so a plan's Kano feature map always lists each one as
**Must-be**, next to the features its journeys need. An app that lacks one fails, however good the
rest is: a cycle-tracking app that can't edit an entry fails, whatever its predictions.

| Must-be | What it means |
| --- | --- |
| Edit | Every item the user creates can be changed after it is saved. |
| Delete | Every item the user creates can be removed, with a confirmation or an undo. |
| Undo | A destructive or bulk action can be taken back right after it, at least once. |
| Search | Anything the user stored can be found again by its text or its date. |
| Backup, export and restore | The user's data leaves the app in an open format (CSV or JSON) and comes back, so moving to a new phone loses nothing. |
| Settings | The choices the app makes for the user (units, start of week, theme, reminders) can be changed in one place. |
| Accessibility | Screen reader labels on every control, dynamic type, contrast of at least WCAG AA, touch targets of at least 48 dp (Android) or 44 pt (Apple), no meaning carried by colour alone. |
| Offline use | Every core journey works without a network; anything that syncs catches up when the network is back. |
| Notification control | The user picks which notifications they get and when, and can turn each kind off in the app. |
| Privacy controls | The user sees what is stored and where, can lock the app, and can erase all their data. |

When a baseline item truly does not apply (an app that stores nothing has nothing to back up),
keep it in the Kano map as Must-be with the reason it is satisfied, rather than dropping it.

## Design quality bar

The screens a plan produces, and the sub-tickets that build them, meet this bar:

- **Platform conventions first.** Material 3 on Android (top app bars, navigation bar or rail,
  floating action button for the main action, Material components and motion); the Human Interface
  Guidelines on Apple platforms (navigation stacks, tab bars, sheets, SF Symbols). A screen that
  departs from the platform says why.
- **Every state is designed.** Each screen shows its empty, loading, filled and error states, and
  any other its journey reaches (offline, permission denied, first use).
- **The main action is obvious.** One primary action per screen, reachable with one thumb on a
  phone.
- **Mistakes are cheap.** Destructive actions confirm or offer undo; forms keep what the user typed
  when they fail.
- **Words are the user's.** Labels use the domain's vocabulary from the domain brief, not internal
  names; error messages say what happened and what to do next.
- **Accessible by default.** The accessibility line of the platform baseline holds on every screen,
  in light and dark themes.
- **Screens are viewable.** The HTML screens file is self-contained (inline CSS and SVG, no web
  fonts, scripts or images from elsewhere), opens in a desktop browser offline and shows every
  screen of the Screens document, each labelled with its journey and name.
