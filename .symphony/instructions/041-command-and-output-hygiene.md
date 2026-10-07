## Command and output hygiene

- For long-running commands (dependency installs, an optional `make all`), use
  longer tool waits such as `yield_time_ms: 30000` to `60000`. Avoid tight
  `write_stdin` polling; if a command is still running, wait at least 30
  seconds before polling again unless there is a specific reason to expect
  immediate failure output.
- Split checks by cost, not by kind. CI is the gate: it runs the full test
  suite, the 100% coverage report and Dialyzer on every push.
  - Cheap checks run locally, in any phase: `mix format --check-formatted`,
    `mix compile --warnings-as-errors`, `mix specs.check`,
    `mix credo --strict <changed files>`, `mix cover.changed` (line coverage
    of the `lib/` modules you changed), `mix settings.ui_coverage`, and the
    test files you added or changed plus the test files of the modules you
    changed (`mix test <file>` or `<file>:<line>`).
  - Slow, compute-heavy checks never run locally: the full `mix test`,
    `make check` and `make test` (both run the whole suite), `mix test --stale`
    (a workspace has no stale manifest on its first run, so it runs all 2,400+
    tests, about 2.5 minutes timed on 2026-10-04), `make coverage`
    (coverage instrumentation recompiles every module and roughly doubles CPU
    and wall time), and Dialyzer. They are several times slower in the
    sandbox than in CI, CI runs them again anyway, and several agents running
    them at once overload the shared host.
  - `make all` stays available as an optional extra for a change to shared
    infrastructure (the config schema, orchestrator core) when you judge a
    full local run worth it. Run it with `TEST_MAX_CASES=2 BEAM_SCHEDULERS=2`
    and record why in the workpad.
  - When a check's cost is unclear, time it once and add it to the right list
    here.
  - Use `make test-profile`, `make coverage-profile`, or `make dialyzer-profile`
    only when a ticket asks you to optimize slow tests or gate behavior.
- In sandboxed Elixir runs, `mix` commands (and `make all`) need no Hex
  install or env overrides. Symphony passes the host's `MIX_HOME` and
  `MIX_ARCHIVES` to the agent so Hex and Rebar resolve, and points `HEX_HOME`,
  `ELIXIR_MAKE_CACHE_DIR` and Dialyzer's core PLTs at a cache folder your
  sandbox may write (`SYMPHONY_AGENT_CACHE_DIR`). Don't set them yourself. The
  test suite keeps MCP socket dirs under a writable `TMPDIR`.
- Your `$TMPDIR` is private to this run (`/tmp/symphony-run-<hash>`), so other
  concurrent runs never write to it: use it directly for scratch files, without
  ad-hoc subfolders to avoid collisions. Symphony removes it when the run
  succeeds.
- In the Claude sandbox, build and test a Swift package (`macos/`) with
  `swift build --disable-sandbox --build-system native` and
  `swift test --disable-sandbox --build-system native`.
  `--disable-sandbox` skips SwiftPM's own `sandbox-exec`, which can't nest
  inside the agent sandbox. `--build-system native` keeps `TMPDIR` for the
  link step: the default Swift Build drops it there and fails with
  `error: permissionDenied`. Symphony lets the sandbox write the per-user
  `TemporaryItems` dir, where Foundation's atomic writes go. Ignore the
  warnings about `~/Library/org.swift.swiftpm` caches and the
  `--build-system native` deprecation. Plain `swiftc` still needs
  `-module-cache-path <workspace dir>`.
- Never run CPU, memory or disk load generators or stress tools on the host:
  no `yes`, busy loops (one per core or otherwise), `stress`, or parallel test
  floods. The machine is shared with other agent runs, QA passes and workspace
  hooks; load slows all of them, and Symphony starts your process tree at a
  lower CPU priority anyway. To reproduce a timing flake, make the race
  deterministic instead: inject the delay or the message order, use the
  injectable clock, and add explicit synchronisation (wait on a message or a
  monitor, not a sleep). Then prove it stable with
  `mix test <file>:<line> --repeat-until-failure N` on the targeted test only.
- Don't leave background processes running: stop any server or watcher before
  ending the turn. Symphony kills whatever is still running in the workspace
  when the run ends.
- Tests and hooks that start login shells (`sh -lc`, `bash -lc`) may print
  `~/.profile: Operation not permitted` inside the sandbox. That is benign: the
  sandbox denies reading shell startup files and the command still runs. Do not
  record it as a workaround.
- Keep tool output focused by default. For broad searches, diffs, and file
  reads, start with targeted `rg` queries, `sed -n` ranges, and modest
  `max_output_tokens` caps. Raise output caps only after narrowing the command
  to the exact file or hunk needed.
