## Command and output hygiene

- For long-running commands (dependency installs), use
  longer tool waits such as `yield_time_ms: 30000` to `60000`. Avoid tight
  `write_stdin` polling; if a command is still running, wait at least 30
  seconds before polling again unless there is a specific reason to expect
  immediate failure output.
{% if run.step_runner %}- Checks are the step list's, not yours. This run follows a step list: after
  your turn Symphony runs the build, the checks and the tests itself, with your
  session closed, and a step that fails brings the run back to the step it
  names with its output. Run none of them: write the code, record what you
  changed, and end the turn. CI is the gate for the full suite, the 100%
  coverage report and Dialyzer, and they never run locally either.
{% else %}- CI is the gate: it runs the full test suite, the 100% coverage report and
  Dialyzer on every push. Locally, a run with no step list runs the test it is
  fixing and the push check, nothing heavier: the slow checks are several times
  slower in the sandbox than in CI, CI runs them again anyway, and several
  agents running them at once overload the shared host.
{% endif %}- In sandboxed Elixir runs, `mix` commands need no Hex
  install or env overrides. Symphony passes the host's `MIX_HOME` and
  `MIX_ARCHIVES` to the agent so Hex and Rebar resolve, and points `HEX_HOME`,
  `ELIXIR_MAKE_CACHE_DIR` and Dialyzer's core PLTs at a cache folder your
  sandbox may write (`SYMPHONY_AGENT_CACHE_DIR`). Don't set them yourself. The
  test suite keeps MCP socket dirs under a writable `TMPDIR`.
- Your `$TMPDIR` is private to this run (`/tmp/symphony-run-<hash>`), so other
  concurrent runs never write to it: use it directly for scratch files, without
  ad-hoc subfolders to avoid collisions. Symphony removes it when the run
  succeeds.
- Never run CPU, memory or disk load generators or stress tools on the host:
  no `yes`, busy loops (one per core or otherwise), `stress`, or parallel test
  floods. The machine is shared with other agent runs, QA passes and workspace
  hooks; load slows all of them, and Symphony starts your process tree at a
  lower CPU priority anyway. To reproduce a timing flake, make the race
  deterministic instead: inject the delay or the message order, use the
  injectable clock, and add explicit synchronisation (wait on a message or a
  monitor, not a sleep). Then prove it stable with a repeated run
  (`--repeat-until-failure N`) of the targeted test only.
- Don't leave background processes running: stop any server or watcher before
  ending the turn. When the run ends, Symphony kills only the agent's own
  process group. A detached process escapes it: it is reparented to launchd in
  another group, and Symphony's stray-process watchdog only reports it, never
  stops it, so it runs until a person notices.
  - Never detach a process: no `( … &)` subshells, `nohup`, `setsid` or
    `disown`. Use your tool's own background mode, such as Bash
    `run_in_background`, which the harness tracks and stops.
  - Bound every probe loop, for example `for i in $(seq 60)`; never
    `while true`.
  - If a process you started can't be stopped (the sandbox refuses `kill`),
    record its pid and full command in the workpad `Notes`, then ask the
    operator with `linear_request_human_action` to kill it. Never move on
    without reporting it.
- Tests and hooks that start login shells (`sh -lc`, `bash -lc`) may print
  `~/.profile: Operation not permitted` inside the sandbox. That is benign: the
  sandbox denies reading shell startup files and the command still runs. Do not
  record it as a workaround.
- Keep tool output focused by default. For broad searches, diffs, and file
  reads, start with targeted `rg` queries, `sed -n` ranges, and modest
  `max_output_tokens` caps. Raise output caps only after narrowing the command
  to the exact file or hunk needed.
