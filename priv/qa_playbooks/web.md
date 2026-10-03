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
started.

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
5. After the last step, read `browser_console_messages` with `all: true` (every message since
   the browser started, not only the last page) and write each message, errors and warnings
   first, to `qa-evidence/console.md` with the page it came from. Write "No console messages."
   when there are none.
6. Attach every step's screenshot and `qa-evidence/console.md` with `linear_attach_file`
   (`make_public: false`), and list the returned URLs in the matching step's `evidence`. Add a last
   step named `console output` whose `evidence` is the `console.md` URL and whose `details` quote
   the errors.

Verdicts for this playbook:

- A page that fails to load, a missing or broken control, or text that contradicts the ticket is a
  failing step; quote the relevant part of the snapshot and attach the screenshot.
- A console error raised by the changed page is a failing step. Warnings, and errors from code the
  change does not touch, go in `details` without failing the step.
- When the `browser` tools are missing or the browser cannot start, answer `blocked` with the
  tool's error as `reason`.
