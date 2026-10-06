# Development

Notes for contributors and operators building, testing, or packaging Symphony.

See also [AGENTS.md](../AGENTS.md) for conventions when working on this repo with coding agents,
and [SPEC.md](../SPEC.md) for the behavior reference for the current service.

## Toolchain

- Elixir `1.19.x` (OTP 28) installed via `mise`.
- `mix setup` to install dependencies.

```bash
mise trust
mise install
mise exec -- mix setup
```

## Pre-push hook

`make setup` runs `git config core.hooksPath .githooks`, which turns on
`.githooks/pre-push` for the clone and all its worktrees (Symphony workspaces get it from
`WORKFLOW.md`'s `after_create`). On every `git push` that changes an Elixir file, the hook runs
`mix format --check-formatted`, `mix compile --warnings-as-errors` and
`mix credo --strict <changed files>`, and rejects the push with the fixing command when one
fails. A push that changes no Elixir file skips the checks. Tests, coverage and Dialyzer stay in
CI. Don't bypass it with `git push --no-verify`; fix what it reports and push again.

`.githooks/pre-push --head` runs the same checks on everything `HEAD` adds since its merge-base
with `origin/main` and records the result in `tmp/push-check`. Symphony's `github_push_branch`
tool skips repo hooks, so it reads that file instead (`push_check` in `WORKFLOW.md`): an agent
runs the command in its sandbox after its last commit. Uncommitted Elixir changes fail this mode,
since the result would not describe `HEAD`.

## Testing

CI fails a push when any module is below 100% line coverage. Before pushing, check the `lib/`
modules your branch changes:

```bash
mix cover.changed
```

It runs the changed test files, the `test/<path>_test.exs` of each changed `lib/<path>.ex` and the
test files that name a changed module, once with `--cover`, then prints each changed module's
coverage with its uncovered lines and fails when one is below 100%. Changes count from the
merge-base with `origin/main` (`--base <ref>` for another branch), uncommitted and untracked files
included. Modules in `mix.exs`'s `test_coverage` `ignore_modules` are skipped, as in CI. When the
tests that cover a module don't name it, pass them: `mix cover.changed <test files>`.

Use the fast local gate while iterating:

```bash
make check
```

`make check` runs the format check, lint, escript build, and plain `mix test`. It does not run
coverage or Dialyzer, so treat it as a confidence check rather than a replacement for CI.

When CPU pressure matters, lower local test concurrency and BEAM scheduler usage:

```bash
make check TEST_MAX_CASES=2 BEAM_SCHEDULERS=2
```

Before pushing, run the full gate:

```bash
make all
```

`make all` also runs `make audit` (`mix hex.audit`), which fails when a locked dependency is
retired or has a security advisory. Update the package with `mix deps.update <package>` rather
than ignoring the advisory.

To find slow validation work before optimizing tests, use the profiling targets:

```bash
make test-profile
make coverage-profile
make dialyzer-profile
```

Inside Symphony's agent sandboxes (Claude Code or SRT-wrapped Codex), plain `make all` runs
green without extra setup:

- Symphony passes the host's `MIX_HOME` and `MIX_ARCHIVES` through to the agent, so sandboxed
  `mix` uses the Hex and Rebar already installed for the host (for example in the per-version
  `MIX_HOME` that `mise` exports).
- The sandbox can't write `~/.hex`, `~/Library/Caches/elixir_make` or the core PLTs in `MIX_HOME`,
  so a local agent gets a cache folder it may write, `~/Library/Caches/symphony/agent`:
  `HEX_HOME` and `ELIXIR_MAKE_CACHE_DIR` point into it, and `mix.exs` keeps Dialyxir's core PLTs
  in it through `SYMPHONY_AGENT_CACHE_DIR`. Symphony copies the host's Hex packages, Hex registry
  cache and `elixir_make` archives into it first (see `SymphonyElixir.AgentCaches`).
- The `after_create` hook compiles the test deps on the host, because `elixir_make` can't
  download `lazy_html`'s precompiled NIF through the sandbox's proxy.
- `test/test_helper.exs` keeps MCP socket dirs under `TMPDIR` when it is short (for example
  Claude Code's `/tmp/claude-501`), under `/tmp` otherwise, and under a long `TMPDIR` (such as a
  run's own `/tmp/symphony-run-<hash>/claude-501`) when `/tmp` is not writable, where sessions
  name their socket dirs after a short hash. If none is writable, set
  `SYMPHONY_MCP_SOCKET_ROOT` to a short writable path; the resulting
  `<root>/symphony-mcp-<id>/sock` must fit the 104-byte Unix `sun_path` limit.
- `bin/symphony` itself needs no setting there: when it cannot write to `/tmp`, it keeps MCP
  socket dirs under `TMPDIR` and logs `MCP socket root=<path>` at startup.
- Workspace hooks keep running under a login shell (`sh -lc`) on the unsandboxed host, where they
  rely on profile-provided `PATH` setup such as `mise`. When tests start login shells inside the
  sandbox, `~/.profile: Operation not permitted` on stderr is expected and harmless.

Run the real external end-to-end test only when you want Symphony to create disposable Linear
resources and launch a real agent session:

```bash
export LINEAR_API_KEY=...
make e2e
```

## Seatbelt tests

The tests tagged `:seatbelt` run commands under the verification dev server's real
`sandbox-exec` profile (see [security.md](security.md)). `test/test_helper.exs` skips them where
`sandbox-exec` can't run: on Linux and inside an agent's sandbox, since Seatbelt can't nest. Run
them on a Mac outside any sandbox with:

```bash
mix test --only seatbelt
```

The [`seatbelt` workflow](../.github/workflows/seatbelt.yml) runs the same command on a macOS
runner, on pull requests and pushes to `main` that change `lib/symphony_elixir/verification/`,
`lib/symphony_elixir/agent_sandbox_config.ex`, `scripts/qa-dashboard-server.sh` or the tests
themselves. It is not a required check.

## Required checks

`main` requires the `make-all`, `macos` and `validate-pr-description` checks. A required check
must report on every pull request: a check that never runs blocks the PR, and GitHub auto-merge
waits on it forever. Don't put a `paths` filter on the trigger of a workflow that holds a
required check. Run it on every pull request, decide in a first job whether anything relevant
changed, skip the expensive jobs when nothing did, and end with a gate job under the required
name that passes when they passed or were skipped. The [`macos` workflow](../.github/workflows/macos.yml)
does this, and only builds the app when `macos/`, `scripts/install-macos.sh` or the workflow
itself changed.

## Packaging

Packaged macOS binaries are built with Burrito and include the Erlang runtime:

```bash
make package
```

Release artifacts are written to `burrito_out/` such as `burrito_out/symphony-macos-arm64`. Set
`BURRITO_TARGET=macos_arm64` to build only that one. Releases ship it inside `Symphony.app`; see
[Releasing](releasing.md). Notarization and a Homebrew tap are not wired yet.

## Why Elixir?

Elixir is built on Erlang/BEAM/OTP, which is a good fit for supervising long-running processes. It
has an active ecosystem of tools and libraries, and it supports hot code reloading without stopping
actively running subagents during development.
