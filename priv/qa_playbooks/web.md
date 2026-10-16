### Playbook: web

Use the web app in a real browser the way a user would and judge what the page shows, not what
the code says. Symphony started the project's dev server for this pass (its address is under
"Dev server" below) and gave you a headless browser through the `browser` MCP server. The browser
can only reach the dev server.

With the default Playwright server the tools are `browser_navigate`, `browser_snapshot` (the
page's accessibility tree, with a `ref` for each element), `browser_click`, `browser_type`,
`browser_wait_for`, `browser_take_screenshot` and `browser_console_messages`. Another browser
server has its own names for the same actions; use its tools the same way.

Do not edit files in the worktree, and do not start a second dev server: use the one Symphony
started. Do not run the project's test suite, `make all`, coverage or static analysis: CI already
ran them.

QA does three things, in this order: (a) the walkthrough steps marked `Proved by: QA` (no test can
drive them), steps 1 to 4 below; (b) the `Design check` of every UI deliverable, by sight, in light
and dark (step 5); (c) the console check (steps 6 and 7).

1. Open the dev server's address. A page that does not load (connection refused, a 500, a blank
   body) is a failing step; quote what the snapshot or the console shows.
2. Follow the ticket's `## User walkthrough` step by step. When there is no walkthrough, open each
   page the change touches (from the acceptance criteria and the changed files) and use the
   controls it adds or changes.
3. After each step, read the page with `browser_snapshot` and judge it against the ticket: the
   text, links and controls it describes are there, have sensible labels, and react when used.
   Wait for the page to settle (`browser_wait_for` on the text you expect) before you judge it.
4. Take one screenshot per step with `browser_take_screenshot`, saved under `qa-evidence/` and
   named after the step in order (for example `filename: "qa-evidence/01-dashboard-open.png"`,
   then `qa-evidence/02-filter-applied.png`).
5. **Design check.** For every page, dialog or panel the change adds or changes, judge it by sight
   in light and in dark against its design: the ticket's or the parent's Screens (named under
   "Design" above), then `docs/design/design-system.md` alone when no Screens cover it.
   - Size: when the design names a viewport size, set it with `browser_resize` (`width`,
     `height`) before the screenshots.
   - Appearance: the browser starts light. Switch to dark with the page's own theme control when it
     has one; otherwise emulate the system setting (with the default Playwright server,
     `browser_run_code` running `await page.emulateMedia({ colorScheme: 'dark' })`, and
     `colorScheme: 'light'` to go back). When the page has no dark appearance (no theme control,
     and nothing changes under the emulated setting) or the browser server cannot switch it, dark
     is not applicable: judge light alone and say so in the step.
   - Take one screenshot per appearance, named with it (for example
     `qa-evidence/05-dashboard-light.png` and `qa-evidence/05-dashboard-dark.png`).
   - Compare layout, spacing, alignment, truncation, contrast, icons, wording, and whether it
     looks finished.
   Report one step per deliverable named `Design check: <deliverable>`, with both screenshots in
   `evidence` and, in `details`, the design it compared with (the Screens document or HTML screen
   and the screen in it, or "the design system alone: no Screens cover it") and the viewport size.
6. After the last step, read `browser_console_messages` with `all: true` (every message since
   the browser started, not only the last page) and write each message, errors and warnings
   first, to `qa-evidence/console.md` with the page it came from. Write "No console messages."
   when there are none.
7. Attach every step's screenshot and `qa-evidence/console.md` with `linear_attach_file`
   (`make_public: false`), and list the returned URLs in the matching step's `evidence`. Add a last
   step named `console output` whose `evidence` is the `console.md` URL and whose `details` quote
   the errors.

Verdicts for this playbook:

- A page that fails to load, a missing or broken control, or text that contradicts the ticket is a
  failing step; quote the relevant part of the snapshot and attach the screenshot.
- A `Design check` whose light or dark screenshot visibly differs from the design (a misaligned or
  clipped element, wrong spacing, unreadable contrast, a wrong icon or wording, an unfinished look)
  is a failing step, even when the snapshot shows every element: in `details` and `findings` name
  what differs from which screen of the design, and attach the screenshot that shows it.
- A console error raised by the changed page is a failing step. Warnings, and errors from code the
  change does not touch, go in `details` without failing the step.
- When the `browser` tools are missing or the browser cannot start, answer `blocked` with the
  tool's error as `reason`.
