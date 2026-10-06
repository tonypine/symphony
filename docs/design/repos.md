# Repos window redesign

- **Ticket:** [TP-695](https://linear.app/tonypine/issue/TP-695/plan-a-redesign-of-the-repos-window-in-the-macos-app),
  a plan under [TP-255](https://linear.app/tonypine/issue/TP-255/manage-connected-repos-from-the-macos-app-local-folder-or-github-url)
- **Why:** Tony, 2026-10-06, after his hand checks of TP-263: "A Redesign in the repos screen, it's terrible."
- **Mock:** [`journeys/repos.html`](journeys/repos.html) shows every screen below, with before-and-after. It is one
  file with no external assets: open it in any browser, offline.
- **Data:** every name, path and issue in this document and the mock is made up.

The Repos window today ([TP-260](https://linear.app/tonypine/issue/TP-260/repos-list-view-in-the-macos-app) list,
[TP-261](https://linear.app/tonypine/issue/TP-261/add-repo-sheet-local-folder-or-github-url-with-linear-project-picker)
Add Repo sheet, [TP-262](https://linear.app/tonypine/issue/TP-262/edit-and-remove-connected-repos-from-the-macos-app)
edit and remove, and the WORKFLOW.md step from
[TP-694](https://linear.app/tonypine/issue/TP-694/set-up-a-workflowmd-as-part-of-adding-a-repo-that-doesnt-have-one))
works. This plan keeps every one of its features and changes how they are laid out and reached.

## 1. What is wrong today

From the QA screenshots of TP-255 (run on `813d59a8`, the "before" frames in the mock):

1. **No hierarchy.** Each repo is a block of six label/value lines, all in the same weight. Two repos fill a
   640×588 window; a third scrolls. Nothing says which repo is fine and which needs work.
2. **"unavailable", four times per repo.** While Symphony is stopped every live field says `unavailable` and the
   window repeats it on every repo, under a grey notice that names the config path in full.
3. **Health is hidden in red text.** A missing `WORKFLOW.md` or a failed fetch shows as a red value in the middle
   of the block. There is no way to act on it from the window.
4. **Long paths win the space.** Full `/tmp/…` and clone paths take more room than the repo's name.
5. **Actions are a row of equal buttons.** Edit sits next to Disconnect, a destructive action, on every repo. A
   disabled Remove Clone explains itself in a caption at the bottom of the block.
6. **One sheet does everything.** Add and Edit share one form: source, key, branch, Linear routing and, on Edit,
   the acceptance gate with four radio buttons and their explanations. The Edit sheet is a fixed 760pt tall, so on
   a 1024×768 screen its Save and Cancel buttons are off-screen (QA fail on TP-263).
7. **Errors push the form around.** A Linear failure shows as large red text in place of the pickers, and why Save
   is disabled shows in a small caption in the footer, far from the field it is about.
8. **Feedback is a line of text.** What the last Add, Edit or Disconnect did, and whether Symphony restarts, is one
   sentence at the top of the window that the next action replaces.
9. **Mac basics are missing.** No empty state, no selection, no keyboard path (⌘N, Delete, arrow keys), no
   VoiceOver label for a status, and the window opens at a fixed size every time.

## 2. Who uses it, and what for

**The operator** runs Symphony on their Mac for one to ten repos. They open the Repos window rarely: to connect a
new repo, to change which Linear issues go where, or because something looks wrong in the menu bar. They know git
and Linear well and don't want to read YAML to do any of this.

| # | Use case | Trigger |
| --- | --- | --- |
| U1 | See what's connected and whether each repo is healthy | Opening the window; the menu bar says something is off |
| U2 | Add a repo: a local folder or a GitHub URL, its Linear routing, and its `WORKFLOW.md` when it has none | A new project starts |
| U3 | Edit a repo's routing, source (local ↔ managed), base branch or acceptance gate | Work moves between projects or labels |
| U4 | Disconnect a repo, or delete Symphony's clone of it | A project ends, or a clone is broken or takes too much space |
| U5 | Spot and fix a problem: a missing or invalid `WORKFLOW.md`, a failed fetch, a stuck agent run | A repo stops taking issues |

## 3. Journeys

Each step names the screen that serves it (section 5).

### J1. See what's connected and its health (U1)

1. Menu bar → **Repos…**. The window opens where it was last, with the last selected repo. → **S1** (or **S0** with no repos)
2. The sidebar lists every repo with a health dot, its `owner/repo`, a **Default** badge and the number of agents
   running, in `symphony.yml`'s order. → **S1**
3. Selecting a repo shows its detail: where the code comes from, its Linear route, `WORKFLOW.md`, recent activity
   and its acceptance gate. → **S1**
4. With Symphony stopped, the toolbar says so once and the detail hides the live sections behind one line with a
   **Start Symphony** button, instead of `unavailable` four times. → **S2**

### J2. Add a repo (U2)

1. Toolbar **+**, sidebar **+**, ⌘N, or the empty state's button. → **S3**
2. **Source.** Paste a GitHub URL or choose a local folder. The sheet checks it right away and shows what it found:
   `owner/repo`, the default branch, whether a `WORKFLOW.md` exists. → **S3**
3. **Linear routing.** Pick the project, then optional labels. A sentence previews the route: "Issues in
   *Billing* with label *backend* go to billing-api." → **S4** (failure: **S4e**)
4. **WORKFLOW.md** (only when the repo has none, TP-694). Edit the pre-filled draft and pick how it lands: a pull
   request (default) or, for a local folder, a file in the checkout. → **S5**
5. **Review and connect.** A summary of what gets written, with the repo key and base branch editable here. Connect
   writes `symphony.yml` (comments kept) and closes the sheet. → **S6**
6. The new repo is selected in the sidebar. A banner on it says how the change reaches Symphony: restarting now,
   after N runs finish, on next start, or restart by hand. → **S11**

### J3. Edit routing, source or gate (U3)

1. Select the repo. Each detail section has its own **Edit…** button. → **S1**
2. **Linear routing…** opens a small sheet with the project, labels, the route preview and **Default repo** (takes
   the issues no other route matches). → **S7**
3. **Source…** opens a sheet with GitHub URL / Local folder, the folder or URL, and the base branch. → **S8**
4. **Acceptance gate…** opens a sheet with the mode as a pop-up (Inherit, Off, Shadow, Enforce), the line on what
   it does, and the gate's record for this repo. Save runs `symphony check` first, as today. → **S9**
5. Save shows the change banner and, when runs are active, the restart question. → **S11**

### J4. Disconnect, or remove the clone (U4)

1. Select the repo, then **Disconnect…** at the foot of the detail, the sidebar **−**, or Delete. → **S10**
2. The sheet says what happens: Symphony stops taking issues for the repo; the folder and branches stay. When it is
   the default repo, a pop-up picks the new default. For a managed clone, a checkbox **Also delete Symphony's
   clone** is on only when no run uses the clone, and says why when it is off. → **S10**
3. The last repo can't be disconnected: the button is off and its help says why. → **S10**
4. To delete only the clone and keep the repo connected, **Remove Clone…** sits in the Source section of a managed
   repo. → **S1**, confirm as today

### J5. Spot and fix a problem (U5)

1. A red or orange dot in the sidebar; the menu bar's Repos item can carry the same count later (out of scope
   here). → **S1**
2. The detail opens with a **Needs attention** box above the sections, one line per problem, each with its fix.
   → **S12**
   - `WORKFLOW.md` missing → **Set Up WORKFLOW.md…** opens TP-694's draft step on its own. → **S5**
   - `WORKFLOW.md` invalid → the error, plus **Open WORKFLOW.md** (local folder: in the default editor; managed:
     on GitHub).
   - `WORKFLOW.md` pending → **View Pull Request**.
   - Last fetch failed → the error (selectable), **Copy Error**, **Open on GitHub**. Symphony tries again before the
     next dispatch, and the line says so.
   - Clone not made yet → information, not a problem: grey, "Symphony clones it on the next dispatch".
   - An agent run with no activity for 10 minutes or more → **Stop Run…** (the control API's stop), **Open in
     Linear**, **Reveal Worktree**. Symphony's own stall timeout (5 minutes by default) should have restarted it,
     so 10 minutes means it is stuck.
3. When the problem clears on the next poll, its line goes away and the dot turns green.

## 4. Kano map

**Must-be, any Mac settings-style window** (the platform baseline; failing one fails the window):

| Feature | How the redesign meets it |
| --- | --- |
| Clear hierarchy | Sidebar of repos, detail of one; section headers; one primary action per sheet |
| Fits the smallest supported screen | Window min 720×460; every sheet ≤ 560pt tall with a fixed footer and scrolling content, so Save is always on screen at 1024×768 |
| Remembers size, position and selection | Window frame autosave; last selected repo restored |
| Empty state | **S0**: no repos, with **Add Repo…** |
| Error states with a way out | No `symphony.yml` set → **Open Settings…**; unreadable file → the error and **Reveal in Finder**; Linear failure → **Retry** and **Open Settings…** |
| Keyboard | ⌘N add, Delete disconnect (with confirmation), ↑↓ in the sidebar, ⌘W close, Return/Esc in sheets, Tab through every control |
| VoiceOver | Each sidebar row reads "billing-api, healthy, default, 2 agents running"; dots never carry meaning by color alone (shape and text label too) |
| Edit and delete | Section edit sheets; Disconnect |
| Destructive actions confirmed and named | Disconnect and Remove Clone confirm, say what stays on disk, and use destructive button styling |
| Light and dark appearance | System colors and materials only |
| Long text handled | Paths truncate in the middle, show in full in help and are selectable; names never wrap the toolbar |
| Live data that doesn't jump | Polls update values in place; selection and scroll keep their position |

**Must-be, specific to Symphony:**

| Feature | Screen |
| --- | --- |
| Every repo with its source, GitHub remote, route, `WORKFLOW.md`, last fetch and running agents (TP-260) | S1 |
| Add a local folder or a GitHub URL with its Linear route (TP-261) | S3–S6 |
| Edit source, base branch, route and gate (TP-262) | S7–S9 |
| Disconnect without deleting the folder; remove a clone only when no run uses it (TP-262) | S10, S1 |
| Writes keep `symphony.yml`'s comments; changes reach Symphony through the graceful restart | S6, S11 |
| A repo with no `WORKFLOW.md` can get one while being added (TP-694) | S5 |

**Performance** (better is better):

| Feature | Screen |
| --- | --- |
| Health at a glance: one dot per repo, problems counted | S1 |
| Each problem with its fix, in one place | S12 |
| Add with less typing: key, base branch and `WORKFLOW.md` presence found from the source | S3, S6 |
| Route preview sentence, so the route is clear before saving | S4, S7 |
| Running agents with how long they have run and their last activity | S1 |

**Attractive** (delights, not expected):

| Feature | Screen |
| --- | --- |
| Set up a `WORKFLOW.md` for a repo that is already connected | S12 → S5 |
| Stop a stuck run from the repo it runs on | S12 |
| Make a repo the default without disconnecting the old one | S7 |
| The gate's agreement record next to its mode | S9 |
| Open in Finder, on GitHub, in Linear from the detail | S1 |

**Indifferent, not planned:** search or filter (one to ten repos), reordering repos, multi-select and bulk
actions, a **Fetch Now** button (needs a new control API endpoint; see decision D5).

## 5. Screens

The window is a standard `NavigationSplitView`: a source-list sidebar on the left (220pt, resizable 180–300) and
the detail on the right, with a unified toolbar. Default size 880×600, minimum 720×460. Title: **Repos**.

### S0. Empty and error states

- **No repos** (`repositories:` empty or missing): centered in the detail, a stack icon, "No repos connected",
  "Connect a GitHub repo or a folder on this Mac, and pick which Linear issues go to it.", and **Add Repo…** as the
  default button. The sidebar is empty.
- **No `symphony.yml` set:** "Symphony doesn't know where its config is." with **Open Settings…**.
- **`symphony.yml` can't be read:** the error in a selectable box, with **Reveal in Finder** and **Try Again**.
- **This Symphony doesn't list its repos** (older Symphony, HTTP 404): the repos from `symphony.yml` with live
  sections hidden, and a line "Update Symphony to see live status."

### S1. Repos window, running

- **Toolbar:** title, a status chip on the right ("Symphony running", green dot; "Restart pending: 2 runs"; see
  S11), and **+** (Add Repo…).
- **Sidebar row:** health dot, repo key in body weight, `owner/repo` (or the folder name) in secondary text, a
  **Default** capsule, and an agent count capsule ("2") while agents run. Context menu: Edit Linear Routing…, Edit
  Source…, Reveal in Finder, Open on GitHub, Disconnect…. Footer: **+** and **−** buttons, as in System Settings
  lists.
- **Detail header:** repo key (title 2), `owner/repo` as a link to GitHub, the **Default** capsule, and a one-line
  health summary ("Healthy", "1 problem", "Not checked: Symphony is stopped").
- **Detail sections** (grouped form, each header with its **Edit…** button where one applies):
  - **Source:** Local folder or Managed clone; the path (middle-truncated, selectable, **Reveal in Finder**); base
    branch. Managed: clone path or "Not cloned yet: Symphony clones it on the next dispatch", and **Remove
    Clone…** (off with its reason as help and a caption while a run uses the clone).
  - **Linear routing:** the preview sentence, then project, labels, team and assignee when set. Default repo:
    "Also takes the issues no other repo's route matches."
  - **WORKFLOW.md:** Valid (path), Invalid (error), Missing, or Pending (pull request open / written, not pushed).
  - **Activity:** last fetch ("12 min ago" or "Failed 3 min ago" with the error), then one line per running agent:
    issue identifier (link to Linear), run time, last activity, worker host when remote, and **Reveal Worktree**.
    "No agents running" otherwise.
  - **Acceptance gate:** the mode ("Inherit: Shadow") and the record line.
- **Detail footer:** **Disconnect…** on the left in destructive style, off with its reason for the last repo.

### S2. Repos window, Symphony stopped

- Toolbar chip: "Symphony stopped" with a grey dot.
- Sidebar dots are grey (unknown), with the label "Not checked".
- In the detail, Source, Linear routing and Acceptance gate show from `symphony.yml` as usual. **WORKFLOW.md** and
  **Activity** collapse into one line: "Live status shows while Symphony runs." with **Start Symphony**.
- Starting, and not answering, read the same way with "Symphony is starting…" and "Symphony isn't answering".

### S3. Add Repo, step 1: Source

Sheet 520×520, with a step indicator at the top ("Source · Linear · WORKFLOW.md · Review"; the WORKFLOW.md step
appears only when needed) and a fixed footer: **Cancel**, **Back**, **Continue** (default).

- Segmented control: **GitHub URL** | **Local folder**.
- GitHub URL: a text field that accepts `https://github.com/owner/repo`, `git@github.com:owner/repo.git` or
  `owner/repo`. Once typing pauses, a result row: "acme/billing-api · default branch main · has WORKFLOW.md", or
  "No WORKFLOW.md on main: you can set one up in a later step". Caption: "Symphony keeps its own clone. Your
  checkouts aren't touched."
- Local folder: **Choose…** then a result row with the folder, its GitHub origin and the same `WORKFLOW.md`
  line. A folder that isn't a git checkout, or has no GitHub origin, shows the reason under the row in red, and
  Continue stays off.
- Continue is off until the source checks out; its help says why.

### S4. Add Repo, step 2: Linear routing

- **Project** pop-up (loading shows a spinner inside the pop-up, not a replacement row).
- **Labels**: a token field with suggestions from the project's labels, instead of a scrolling list of checkboxes.
- The route preview sentence, updated live.
- A route identical to another repo's shows inline under the labels: "invoices already takes these issues. Pick
  other labels or another project."
- **S4e, Linear failure:** an inline warning box ("Linear rejected the API key." / "Linear lists no projects for this
  key." / the error), with **Retry** and **Open Settings…**. The rest of the sheet keeps its place.

### S5. Add Repo, step 3: WORKFLOW.md (only when the repo has none)

The TP-694 step, given its own page instead of a section in a long form.

- "billing-api has no WORKFLOW.md on main. Symphony needs one to run agents on it."
- What was found ("Elixir · mix test · base branch main"), and the editable draft in a monospaced editor that fills
  the page.
- **Add it by:** Pull request (default) · Write it into the checkout (local folder only) · Don't create it now.
- The same page opens on its own from S12's **Set Up WORKFLOW.md…** for a connected repo, with **Create** in place
  of Continue.

### S6. Add Repo, step 4: Review and connect

- A summary: source, GitHub, route sentence, `WORKFLOW.md` choice.
- **Repo key** (filled from the repo name, editable, checked for duplicates inline) and **Base branch** (filled
  from the default branch, editable).
- When the file has one unscoped repo, the line "notes-app becomes the default repo, so it keeps the issues no route
  matches."
- What happens next: "Symphony restarts to connect it" / "after 2 agent runs finish" / "when it starts".
- **Connect** (default). A write error stays on this page in a warning box; nothing is written.

### S7. Edit Linear routing

Sheet 480×420: project, labels (as S4), the route preview, the **Default repo** checkbox ("Take the issues no other
repo's route matches"; turning it on moves the default from the current one, named in the caption), and **Cancel** /
**Save**. A project Linear doesn't list, or a label it doesn't list, stays selectable as today.

### S8. Edit source

Sheet 480×380: GitHub URL | Local folder, the URL or **Choose…** with the same check as S3, base branch, and a
caption on what switching does ("Symphony makes its own clone on the next start. Your folder stays as it is.").
The key shows in the title ("Source of billing-api") and can't change, as today.

### S9. Edit acceptance gate

Sheet 440×300: **Mode** pop-up (Inherit (Shadow), Off, Shadow, Enforce), the one-line explanation of the choice, and
the repo's record line ("12 decided, 11 agreed with the reviewer"). Picking Enforce asks first, as today. Save runs
`symphony check` with a spinner in the footer, and shows its rejection inline.

### S10. Disconnect

Sheet 440×auto, in place of the alert:

- Title "Disconnect billing-api?" and the text on what happens and what stays on disk.
- Default repo: **New default** pop-up.
- Managed clone: **Also delete Symphony's clone (~/.local/share/symphony/repos/acme/billing-api)**, off with the
  reason when a run uses it or Symphony isn't answering.
- **Cancel** and **Disconnect** (destructive).

### S11. Change feedback

- A banner at the top of the changed repo's detail (or, after Disconnect, of the newly selected repo): "Added
  billing-api. Symphony restarts to connect it." It stays until dismissed or the next change.
- The toolbar chip shows a pending restart: "Restart pending: waiting on 2 runs", with a pop-over that offers
  **Restart Now** (waits for runs, as today) and **Cancel Restart**.
- When runs are active, the restart question still asks first, as an alert sheet on the window: **Restart When Runs
  Finish** / **Later**.

### S12. Needs attention

A box above the detail sections, orange for warnings and red for errors, one row per problem with its fix button
(see J5.2). Problems Symphony reports and the app derives:

| Problem | From | Fix |
| --- | --- | --- |
| `WORKFLOW.md` missing | `/api/v1/repos` `workflow.status` | Set Up WORKFLOW.md… (S5) |
| `WORKFLOW.md` invalid | same, with `error` | Open WORKFLOW.md |
| `WORKFLOW.md` pending | the app's pending store (TP-694) | View Pull Request / Reveal in Finder |
| Last fetch failed | `last_fetch.result` and `error` | Copy Error, Open on GitHub |
| Stuck run: no activity for 10 min | `/api/v1/state` running `last_event_at`, joined on `worktrees[].issue_identifier` | Stop Run…, Open in Linear, Reveal Worktree |
| Symphony couldn't list running agents | `/api/v1/repos` `error` | Information only |

## 6. Every current feature has a screen

| Feature today | Ticket | New screen |
| --- | --- | --- |
| One row per `repositories:` entry, by key | TP-260 | S1 sidebar row, detail header |
| Default marker and its help | TP-260 | S1 Default capsule, routing line |
| Source: local folder path, managed clone, "not cloned yet" | TP-260 | S1 Source |
| GitHub remote | TP-260 | S1 header link |
| Linear routing: team, project(s), labels, assignee | TP-260 | S1 Linear routing |
| `WORKFLOW.md` found/valid, invalid, missing, with path and error | TP-260 | S1 WORKFLOW.md, S12 |
| Last fetch: when, ok or failed with error, "none yet" | TP-260 | S1 Activity, S12 |
| Running agents: issue, worker host, worktree paths | TP-260 | S1 Activity |
| Acceptance gate field per repo | TP-260 / gate | S1 Acceptance gate |
| Refresh while open | TP-260 | S1, S2 (unchanged polling) |
| Stopped, starting, not answering: rows from `symphony.yml` | TP-260 | S2 |
| No `symphony.yml` set, unreadable, no `repositories:`, older Symphony, unreachable, agents not listed | TP-260 | S0, S2, S12 |
| "Symphony lists no repos." | TP-260 | S0 |
| Why Edit or Disconnect is off | TP-262 | S1 button help and caption, S10 |
| Add Repo… button | TP-261 | S1 toolbar and sidebar +, ⌘N, S0 |
| GitHub URL in three formats, with the clone caption | TP-261 | S3 |
| Local folder: choose, check git, GitHub origin, `WORKFLOW.md` | TP-261, TP-694 | S3 |
| Repo key suggested from the name, editable, duplicate check | TP-261 | S6 |
| Base branch, default `main` | TP-261 | S6 (now from the default branch) |
| Linear project picker: loading, failure with Retry, no projects | TP-261 | S4, S4e |
| Labels of the picked project: loading, failure with Retry | TP-261 | S4 |
| Route caption; twin-route and missing-project checks | TP-261 | S4 preview and inline errors |
| Save writes `symphony.yml` with comments kept; first repo made default | TP-261 | S6 |
| Restart now, ask when runs are active, on next start, restart by hand | TP-261 | S6 line, S11 |
| `WORKFLOW.md` draft and how it lands | TP-694 | S5 |
| `WORKFLOW.md` pending in the list | TP-694 | S1 WORKFLOW.md, S12 |
| Edit… on a repo, key read-only | TP-262 | S7, S8, S9 (key in the title) |
| Switch local ↔ managed | TP-262 | S8 |
| Change routing, keep unlisted project and labels | TP-262 | S7 |
| Change base branch | TP-262 | S8 |
| Acceptance gate per repo, Enforce confirmation, `symphony check` before writing, record line | TP-262 / gate | S9 |
| Disconnect…: confirmation, what stays on disk, new default pick, last repo blocked | TP-262 | S10 |
| Remove Clone…: managed only, blocked while a run uses it or Symphony isn't answering, checked again before deleting, path inside the clones folder | TP-262 | S1 Source, S10 checkbox |
| Restart question after Edit and Disconnect, and "later" message | TP-262 | S11 |
| What the last change did, and save errors | TP-261/262 | S11 banner, inline errors in sheets |

## 7. Decisions

### D1. Layout: sidebar and detail

- **A. Sidebar + detail (recommended).** What Mail accounts, System Settings and Xcode's Accounts pane do. The list
  is scannable, the detail has room for health, and it scales to ten repos.
- B. One list with rows that expand. Keeps today's shape, but a long block still pushes the others away.
- C. A table with one column per field. Scans well, but paths and errors don't fit in cells.

### D2. Editing: one small sheet per section

- **A. A sheet per section (recommended):** Linear routing, Source, Acceptance gate. Each fits a 768pt screen, has
  one job, and keeps today's "review, then write `symphony.yml`" model.
- B. Edit in place in the detail with Save and Revert. Fewer windows, but a half-edited detail keeps polling, and
  every change still needs a restart, so in-place editing promises a live effect it doesn't have.
- C. Keep one Edit sheet, with a scroll and a fixed footer. Fixes the QA bug only.

### D3. Add Repo: a sheet in steps

- **A. Steps (recommended):** Source, Linear, WORKFLOW.md when needed, Review. Each page has one question; the
  `WORKFLOW.md` draft gets a full page; errors stay next to their field.
- B. One scrolling form, as today, with a fixed footer. Shorter to build; the `WORKFLOW.md` editor still crowds it.

### D4. Where the design documents land

The ticket asks for `docs/design/repos.md` and `docs/design/journeys/repos.html` "on a PR". A `breakdown` parent
never opens a PR in Symphony's workflow, and a PR on the parent could go through Auto Review and the acceptance
gate, which this plan must not.

- **A. A docs-only sub-ticket lands them (recommended).** Both files are attached to TP-695 for this review; the
  first sub-ticket, TP-706, opens the PR, and every build sub-ticket waits on it and reads the design from the repo.
- B. Leave them on the ticket only. Build agents would need the attachment links, which expire.

### D5. A failed fetch: show it, don't add Fetch Now

- **A. Show the error with Copy Error and Open on GitHub (recommended).** Symphony fetches again before each
  dispatch; the usual causes (auth, network, a renamed repo) are fixed outside the app.
- B. Add a Fetch Now button. Needs a new control API endpoint; can follow as its own ticket if wanted.

### D6. When a run counts as stuck

- **A. No agent activity for 10 minutes (recommended):** twice Symphony's default stall timeout
  (`codex.stall_timeout_ms`, 5 minutes), after which Symphony should already have restarted the run.
- B. Use the configured stall timeout. More exact, but the app would have to read it from `symphony.yml` or the API.

## 8. Build plan

Sub-tickets of TP-695, in landing order. Each is one PR with a user walkthrough for macOS QA.

| Ticket | Sub-ticket | Screens | Kano | Blocked by |
| --- | --- | --- | --- | --- |
| TP-706 | Land the Repos redesign documents | all | — | — |
| TP-707 | Sidebar and detail layout, sizes, empty, stopped and error states, keyboard and VoiceOver | S0, S1, S2 | Must-be | TP-706 |
| TP-708 | Change feedback: banners and the restart chip in place of the message line | S11 | Must-be | TP-707 |
| TP-709 | Health: sidebar dots and the Needs attention box, with stuck runs | S1, S12 | Performance | TP-707 |
| TP-710 | Add Repo in steps | S3–S6 | Must-be | TP-708 |
| TP-711 | Edit sheets per section, with Make Default | S7–S9 | Must-be | TP-708, TP-710 |
| TP-712 | Disconnect sheet with the clone checkbox | S10 | Must-be | TP-708 |
| TP-713 | Set up WORKFLOW.md for a connected repo | S12 → S5 | Attractive | TP-709, TP-710 |
| TP-714 | Final verification | — | — | TP-706 to TP-713 |

TP-710 builds on TP-694's `WORKFLOW.md` step, which must be merged first.
