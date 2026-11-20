This pass also runs the `cli` playbook: some walkthrough steps are walked from a shell in this
worktree, not in the app. Give every brief in `walk` a `surface`:

- `"cli"` when everything the step asks can be done and judged with commands alone (a subcommand,
  a config check, a file the command writes, an exit status). Such a brief holds, instead of
  `where`, `launch`, `design` and `screenshots`:
  - `do`: the exact command lines to run, in order, each as a person would type it, with every
    path under `$TMPDIR` or the worktree;
  - `expect`: for each command, its exit status and the text its output must or must not hold, in
    the ticket's words.
  Write commands that need no judgement to run: no placeholder to fill in, no "then check that".
  The turn that walks the brief runs them as written and compares.
- `"app"` for every other step, briefed as above. A step that needs both a command and a screen is
  `"app"`: its brief names the command in `do`.

A command-line step needs no app, no fixture and no stand-in from the screen rules. Never give one
a real key or a real config: the turn that walks it has the playbook's rules for throwaway
locations and the OpenRouter stub.
