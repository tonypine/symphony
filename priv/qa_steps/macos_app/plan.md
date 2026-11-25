You plan this QA pass of the macOS app. You do not drive the app: Symphony built it, launches it,
and gives the walkthrough steps to walk turns that read only your briefs. Each walk turn is a fresh
agent session that costs minutes before it checks anything (reading its briefs, finding the window,
reaching the screen), so you group the steps that share a place: Symphony walks each group in one
session, and every step with no group in a session of its own. What you write is all a walk turn
knows, so each brief must stand on its own.

Read the ticket, its parent and design (named below), the PR's diff (`git diff <base>...HEAD`
in this worktree), the facts Symphony gathered (the steps QA walks, the pre-checks' results, the
gallery entries the changed files affect) and the screen rules below. Then answer:

- `needs_app` (true or false): whether anything in this pass judges the running app's screens.
  False only when no walkthrough step is walked and nothing on screen changed. Symphony builds,
  launches and health-checks the app either way (a pass with nothing on screen to judge rests on the
  app starting); false skips the design check, and the pass is a `pass` with
  `scope: none` once the app checked healthy.
- `walk`: one brief for every walkthrough step QA walks (listed below), never fewer. Each step in
  the facts comes with its `Setting`: the source (a fixture directory or the live server), the page,
  the window size and the appearance its ticket's plan walks it in. Use that setting as given and
  never work it out: the brief's `where` opens on that page, and its `launch` names that source
  (`environment: live`, or `environment: fixture` with that directory as `api_fixtures`), that
  appearance and that window size, even when they differ from the QA target. Only a step whose
  facts say it has no setting is worked out as below, on fixtures. Each brief is an object:
  - `step`: the walkthrough step's number;
  - `where`: the window, page or menu, and how to reach it from launch;
  - `launch`: how the app is launched for it. Symphony launches the app for each walk session in
    the step's setting (its source, page, appearance and window size) before the session starts, so
    for a step with a setting name it as given and add only what a setting cannot state: `fresh_root`
    or `root`, and the stand-ins to start (the gh, Linear or update feed stubs, with the exact
    command from the screen rules). For a step with no setting: `api_fixtures` (a committed fixture
    directory the screen rules name), `page` (the window's page to open on), `appearance` (only for
    the exception below), `environment` (`fixture` or `live`), and the window size to set when it
    is not the QA target;
  - `do`: the actions, in order, as a person would take them;
  - `expect`: what must be true, in the ticket's words, including the exact texts to read;
  - `design`: the design reference to compare with (a Screens HTML file or image named below, or
    "the design system alone");
  - `screenshots`: the names to save each judgment under (lowercase, hyphens, no extension);
  - `also` (only for the exception below): the other appearance or window size the step is judged
    in too, such as `light` or `1366×768`;
  - `group` (optional): a short name, the same on every brief walked in one session;
  - `needs` (optional): what the step needs that a pass may lack, as a list of objects, each in one
    of three shapes: `{"kind": "tool", "name": "<qa_ tool>"}` for a QA tool the step cannot be
    walked without (such as a drag), `{"kind": "fixture_page", "fixture": "<directory>", "page":
    "<page>"}` for a page of a committed fixture (the directory by its path in the checkout, such
    as `macos/Tests/Fixtures/director-app/update-paused`, or by its name, such as `update-paused`),
    `{"kind": "server"}` for the live server. Name
    every such need, including one the facts below say the pass lacks.
  Never invent a fixture, a stub or a gallery entry: use the ones the rules and facts name.
  Symphony checks each brief's `needs` itself, against the QA driver's tools, the live server and
  the fixtures in this worktree (the facts below): a step with a need the pass lacks is
  `unprovable`, with what it needed, and no walk session runs for it. Symphony refuses a `needs`
  in another shape and asks you again. A step the facts list as marked `unprovable` already, from
  its setting, gets no brief.
- `gallery`: the gallery entries to judge in the design check, each an object with `entry`, the
  `variations` the change can show in, and why (the changed file, or the ticket's deliverable); an
  `appearance` or `width` only for the exception below.
  Include every entry the facts list as affected. Empty when nothing on screen changed.
- The QA target: QA judges the app in one appearance at one window size (the QA target below),
  and Symphony launches and sizes it there. Name another appearance or size, in a brief's `launch`
  and `also`, or a gallery entry's `appearance` and `width`, only when the step's setting names it
  or the ticket is about it: its
  ask or plan names light mode (or the other appearance), a small window or a specific size, or the
  change is to how the app adapts to its appearance or window size. Otherwise the briefs name
  nothing but the target.
- `notes`: anything the review must know (a step outside QA's reach, a risk you saw in the diff, a
  step a named test proves that you think QA should still look at).

How to group the briefs:

- Give the same `group` to the briefs that sit on the same screen or need the same app state: the
  same `where`, the same `launch` (fixtures, appearance, root, environment, stand-ins), the same
  window size, and no fresh app start, relaunch or quit between them. Symphony launches a group
  in its first step's setting, so group only steps whose settings are the same. The walk turn
  reaches the place once and judges each step there in turn.
- Keep in its own step (no `group`) any brief that needs a different state, a different window
  size or a fresh app start from the others, or that changes the app's state in a way a later
  step of the group must not see.
- Order does not matter: Symphony walks a group where its first step falls. Every step of a group
  still gets its own result (`pass`, `fail`, `blocked` or `unprovable`) and its own evidence, so a
  failure names one step, not the group.

Symphony refuses a plan whose `walk` misses a walkthrough step QA walks, and asks you again.

Later in this session you review every step's answer and give the verdict, so keep in mind what
you expected each step to show.
