# Security

Symphony runs autonomous coding agents against real repositories, real tracker accounts, and real
GitHub remotes. This document describes what Symphony does to keep those actions contained, and the
operational practices an operator should layer on top.

## Threat Model

Symphony is designed against three primary risks:

- **A misbehaving agent** that wanders outside the current issue's workspace, leaks secrets, or
  pushes to the wrong remote.
- **Untrusted tracker input** — anyone who can edit a Linear issue can attempt prompt injection
  through the title, description, or comments.
- **Operational mistakes** that expose the unauthenticated dashboard or quality-gate provider
  traffic to the public network.

It is *not* designed to safely execute work submitted by anonymous third parties, nor to act as a
public multi-tenant service.

## What's Included

### Per-issue isolated workspaces

Every run gets a fresh workspace under the configured `workspace.root`. Source repositories are
never used as the agent's working directory. Workspaces are subject to age-based cleanup, startup
orphan reporting, and free-disk-space dispatch pauses (`workspace.disk.*`).

### Sandbox defaults for the agent process

For Codex, Symphony applies safer defaults whenever the operator does not override them
(see [docs/configuration.md](configuration.md)):

- `agent.thread_sandbox` defaults to `workspace-write` — writes are scoped to the current issue
  workspace.
- `agent.turn_sandbox_policy` defaults to a `workspaceWrite` policy rooted at that workspace.
- `agent.approval_policy` defaults to `reject` for `sandbox_approval`, `rules`, and
  `mcp_elicitations`, so the agent cannot cross those policy boundaries on its own.
- `agent.network_access.mode` defaults to `allowlist` — the agent talks only to Symphony's
  built-in dev domains plus the operator's `allowed_domains`, minus `denied_domains`.

A managed permission profile carries a built-in **credential/config read-deny list** covering paths
such as `~/.ssh`, `~/.aws`, `~/.config/gh`, `*.pem`, `*.key`, and the agent runtime credential
stores under `~/.codex` and `~/.claude`. `workspace.sandbox.allow_read_paths` lets you carve narrow
exceptions when a repo legitimately needs something like `~/.npmrc`.
`workspace.sandbox.allow_write_paths` is the write-side counterpart: it adds entries to the Claude
runtime's `sandbox.filesystem.allowWrite` so the agent can write under specific host paths beyond
the Claude Code default (workspace + `/tmp`). Codex/SRT already authors a broader writable set
under `/tmp` and the workspace, so this knob only affects the Claude runtime today.
On macOS, Symphony also adds the per-user `TemporaryItems` dir
(`$(getconf DARWIN_USER_TEMP_DIR)TemporaryItems`) to a local Claude run's `allowWrite`.
Foundation stages atomic file writes there in a sandboxed process, so `swift build` and
`swift test` fail without it. The rest of the per-user temp dir stays read-only: Symphony keeps
each session's Claude settings and the MCP shim there.

Both runtimes also deny writes to the workspace's own instructions and workflow files:
`WORKFLOW.md`, `symphony.yml`, the project `.claude/` settings, agents, commands and hooks, and the
skill directories `.ai/skills`, `.claude/skills` and `.codex/skills`. In a local workspace the deny
also covers the files a symlink in one of those points at: Symphony's own `.ai/skills/pull` links
to `priv/skills/pull`, so `priv/skills/pull` is read-only to the agent. An SSH worker's workspace
gets the plain list.

A `git merge` in the sandbox therefore fails when the base branch changed one of them, so agents
merge the base branch with `github_sync_base`, which merges outside the sandbox with repo hooks off
and leaves the commit to the agent. It and `github_push_branch` refuse a branch that changes one of
those paths, or a symlink's target, itself. The refusal binds only those tools: a `git push` from
the agent's shell skips it (Claude's settings deny `git push`, but only as a command pattern), and
the tools then trust what that push put on the branch.

The `protected-paths` CI workflow covers that gap. On a pull request from an `auto/*` branch it
runs `mix protected_paths.check`, which fails when the pull request's own commits since the
merge-base with the base branch change one of those paths or a symlink's target. Changes merged
from the base branch pass. It runs only on `pull_request_target`, so the workflow and the check
come from the base branch and the pull request can't change them. A person who made such a change
on purpose waives it for the current head commit in one of two ways, so a later push is checked
again. Adding the `protected-paths-approved` label waives the head the pull request has at that
moment; to waive a later head, remove and re-add it. It counts only when a person other than the
pull request's author adds it, since an agent may act as the author. An approving review of the
current head commit counts too, but only from a reviewer with write access (an owner, member or
collaborator), since anyone who can read the repository can approve. A review doesn't start a run,
so after approving, re-run the job. Bots count for neither. The workflow tells Symphony's pull
requests apart only by the `auto/` branch prefix. So it skips the case where a person's own open
pull request on another branch is attached to the issue, and Symphony keeps working on that
branch.

Every local agent may also write one per-user cache folder, `~/Library/Caches/symphony/agent` on
macOS, which holds its Hex home, its `elixir_make` cache and Dialyxir's core PLTs (see
`permissions.filesystem.allow_write_paths` in [configuration](configuration.md)). Runs share it,
so one run can change what a later run reads: Hex checks each package tarball against the checksums
in `mix.lock`, and `elixir_make` checks each precompiled archive against the package's checksum
file, before using it. The host's own `~/.hex` and `~/Library/Caches` stay read-only, and the
folder never holds `hex.config`, which can hold Hex API and repo keys.

### Workspace hooks run outside the sandbox

A repository's `hooks` run on the host (or the SSH worker) as the operator, outside the agent
sandbox: they can reach the Keychain, SSH keys and the tokens in Symphony's environment. Symphony
reads the hook scripts from the `WORKFLOW.md` committed on the fetched base branch, never from
the agent's checkout. But a hook that runs the repo's build tool (`mix`, `npm`, `gradle`, `make`)
runs whatever code the checkout holds: any `mix` command evaluates `mix.exs`, and
`mix deps.compile` runs the dependencies' build scripts.

- **`after_create` in a local worktree runs on the base branch's tree.** A worktree can be created
  on a branch an agent already pushed to: a rework or PR run checks out the PR head, and a removed
  workspace is made again on its existing `auto/<issue>` branch. When the worktree's tree differs
  from the base commit (the repository's `base_branch`, else a `workspace.source` clone's
  `origin/HEAD`, else the source repo's `HEAD`), Symphony detaches the worktree at the base commit,
  runs the hook, and checks the branch out again. Before the hook, Symphony removes the ignored
  files in the worktree (`git clean -ffdx`), so a reused worktree's hook never loads the `deps/` or
  `_build/` an agent wrote there. A worktree with uncommitted changes, or one whose base commit
  can't be resolved, skips the hook with a warning and keeps its pending marker. The
  hook installs the base branch's dependencies, so a branch that changes its lock file runs on
  them until the agent fetches its own.
- **`after_create` on an SSH worker, or in a `clone`-strategy workspace,** runs on whatever the
  workspace holds (TP-524 covers SSH workers). A hook that clones the repo itself should install
  dependencies before it checks out an agent's branch.
- **`before_run`, `after_run` and `before_remove` run in the agent's checkout,** after the agent
  has written to it: a branch's files, and also ignored ones such as `deps/` and `_build/`. They
  should run nothing from the checkout: no build tool, no script from the repo, and no
  `mise exec`, which reads the checkout's mise config. `before_remove` gets the repo and branch
  from `SYMPHONY_REPO` and `SYMPHONY_BRANCH`.
- Symphony's own git commands in a workspace run with repo hooks and `core.fsmonitor` off, and a
  local hook runs Gradle without a daemon (see [configuration](configuration.md#workspace-hooks)).

Host-side steps of Symphony's own `WORKFLOW.md` hooks:

| Hook | Step | Why it runs on the host |
| --- | --- | --- |
| `after_create` | `git config core.hooksPath .githooks` | Writes the shared repo config, which the sandbox can't. The hooks then run in the agent's own `git` commands, inside its sandbox; Symphony's git turns them off. |
| `after_create` | `mise trust` | Trusts the base branch's mise config for the workspace path, so `mise exec` reads it. |
| `after_create` | `mise exec -- mix deps.get` | Fetches the base branch's Hex dependencies, on the base branch's tree. |
| `after_create` | `MIX_ENV=test mise exec -- mix deps.compile` | `lazy_html` downloads its precompiled NIF, which the sandbox's proxy refuses. Runs on the base branch's tree. |
| `before_remove` | `mise exec -- mix workspace.before_remove` | Closes the branch's open pull requests with the operator's `gh` login. It still evaluates the agent's checkout (`mix.exs`, `deps/`, `_build/`, the mise config trusted above); TP-523 replaces it with plain `gh` calls. |

### No windows on the host desktop

On a macOS host, agents run on the operator's desktop, so a GUI program an agent starts puts its
windows, and its "quit unexpectedly" dialog when it crashes, on the operator's screen.

- The managed runtime context tells every agent never to launch an app, an `NSApplication`, or a
  window on the host. UI screenshots come from offscreen rendering (SwiftUI `ImageRenderer`) or
  from the QA pass, which drives the app on its own QA machine.
- The Claude Code and SRT Seatbelt profiles allow only a fixed list of mach services, and the
  window server (`com.apple.windowserver.active`) is not on it. Symphony never adds to that list
  (`allowMachLookup`) or turns on `allowAppleEvents`, so an AppKit program started in the agent
  sandbox gets no window server connection and can't draw. Offscreen `ImageRenderer` snapshots
  still work.
- The profiles still allow LaunchServices (`com.apple.coreservices.launchservicesd`), which the
  runtimes don't let Symphony turn off. An AppKit program that crashes without a window server
  may still produce a crash dialog, so the prompt rule is what keeps agents from starting one.

### Optional outer sandbox (Codex + SRT)

Set `agent.sandbox_runtime.kind: srt` to wrap Codex with
`@anthropic-ai/sandbox-runtime`. Symphony generates a temporary SRT settings file with deny-reads
on the credential paths, allow-writes scoped to the issue workspace, and an `externalSandbox` turn
policy so SRT — not nested `sandbox-exec` — owns command enforcement. Use this when native Codex
deny-list enforcement is not enough.

**Git write model.** SRT settings always deny writes to the high-risk Git metadata files
`config`, `config.worktree`, `hooks`, `info`, `packed-refs`, and any `worktrees/*/config(.worktree)`
entries on every discovered Git metadata root. Writes to `.git/objects` remain allowed so `git add`
and `git commit` work in both clone workspaces and linked worktrees. For linked worktrees
(`workspace.strategy: worktree`, `workspace.repo: <source>`), those object writes target the
shared `<source>/.git/objects` database; this is an intentional cleanup/blast-radius tradeoff so
SRT-wrapped Codex can commit normally while config, hooks, packed refs, and other high-risk Git
metadata stay write-protected.

**Known issue.** Codex app-server sessions wrapped by SRT can fail while writing stdout with
`Resource temporarily unavailable (os error 35)`, surfaced by Symphony as
`:codex_stdio_write_failed`. Symphony drains and compacts app-server output after receipt, but this
failure occurs before the frame reaches Symphony. Disable SRT for Codex on stability-sensitive runs
until the Codex/SRT stdio behavior is hardened.

### Network access controls

`agent.network_access` supports `allowlist`, `block`, and `open`. `denied_domains` always
overrides built-in and user-supplied `allowed_domains`. Quality-gate and orchestrator HTTP traffic
are *not* covered by these switches — see Best Practices below.

### Untrusted-input handling

Linear titles, descriptions, and comments are rendered into the prompt inside bounded `<linear_...>`
blocks. Issue titles, descriptions, acceptance criteria and comment bodies escape only the `<` that
opens a `<linear_...>`, `<github_pr_...>` or chat role tag (`<system>`, `<user>`, ...), so the agent
can copy a ticket section into its workpad, or rewrite its workpad from a read, without storing HTML
entities, and the text still can't close its block. Other fields (state, reviewer comments, CI
logs, QA findings, PR conflict metadata) have every `&`, `<` and `>` escaped. Symphony also prepends a managed runtime context that instructs the agent to treat
Linear/GitHub/CI/tool-output boundaries as data only, work only in the prepared workspace, prefer
scoped tools, and avoid common secret paths. Repo `WORKFLOW.md` files can add stricter repo-local
rules, but they do not need to duplicate those Symphony-owned guardrails.

### Scoped Linear and PR tools

During app-server sessions, Symphony exposes scoped client-side `linear_*` tools so the agent can
only read and update the **current** Linear issue, not arbitrary issues. PR evidence and
attachment handling go through the same scoped surface.

### Dispatch and budget caps

- `agent.max_concurrent_agents`, `agent.max_turns`, `agent.max_tokens_per_issue`, and
  `agent.max_tokens_per_day` cap blast radius and spend.
- Watchdog detects no-progress sessions and recovers them; failed runs back off through the retry
  queue.
- `Pause Dispatch` (dashboard or `mix symphony.pause`) survives restarts and is persisted with the
  pause reason.

### Quality gate isolation

The optional quality gate runs in the orchestrator, not in the agent sandbox. It is documented
separately in [quality_gate_security.md](quality_gate_security.md), including its prompt-injection
surface, the `on_error: pass` failure mode, and the lack of in-process network restrictions on
provider calls.

### Tamper-evident audit log

Side-effect events (prompt sends, tool calls, file changes, PR actions, Linear state/comment
actions, token deltas) are appended to `<state-root>/audit/YYYY-MM-DD.ndjson`. Each record carries
`previous_hash` and `record_hash` so the chain is verifiable with
`SymphonyElixir.AuditLog.verify_file/1` or `mix symphony.audit`. Prompts are stored as SHA-256
hashes plus a redacted preview — never raw — and configured secrets and common API-key env vars
are scrubbed before write. See [logging.md](logging.md).

### Local-only dashboard bind

The LiveView dashboard and `/api/v1/*` endpoints have **no built-in authentication**. Symphony
refuses to bind to non-loopback hosts unless `SYMPHONY_ALLOW_REMOTE_BIND=1` is set explicitly, and
the error message points operators at a reverse-proxy front door (Tailscale, Cloudflare Access,
nginx basic auth, etc.).

### Credentials from environment, not from config

Secrets (`LINEAR_API_KEY`, `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, notification webhook auth) are
read from environment variables. The quality gate explicitly ignores credentials placed in
`WORKFLOW.md`.

## Best Practices

### Deployment

- Keep `SYMPHONY_SERVER_HOST=127.0.0.1` and front the dashboard with an authenticated reverse proxy.
  Only set `SYMPHONY_ALLOW_REMOTE_BIND=1` when you know exactly what is in front of the port.
- Apply infrastructure-level egress filtering on the Symphony host or container. The orchestrator's
  HTTP calls (tracker, quality gate, learnings, notifications) are not covered by the agent's
  in-process network controls.
- Persist `<state-root>` on storage you trust, and back up `audit/` and `run_store/` if you need
  long-term traceability.

### Tracker hygiene

- Restrict who can edit issues that fall inside Symphony's poll filter. Anyone who can edit an
  issue can attempt prompt injection through its content.
- If issue editing is open to a wider audience, consider `quality_gate.on_error: skip` and a
  stronger scoring model, as discussed in [quality_gate_security.md](quality_gate_security.md).

### Sandboxing

- Prefer `agent.sandbox_runtime.kind: srt` when you need credential deny rules enforced at the OS
  layer rather than as a best-effort Codex profile. Native Codex enforcement of the managed deny
  list is best-effort across versions.
- Keep `agent.approval_policy` at its `reject` defaults unless an unattended use case truly
  requires `auto_approve_all`, and never combine `auto_approve_all` with `thread_sandbox:
  danger-full-access`.
- Treat `workspace.sandbox.allow_read_paths` as an escape hatch. Add only the narrowest path you
  need (e.g. `~/.npmrc`), never a directory containing other credentials.
- Treat `workspace.sandbox.allow_write_paths` the same way for the Claude runtime. Grant only
  paths the agent legitimately needs to write — e.g. a known MCP socket root — not broad parents
  like `/private/tmp`.
- Keep `agent.network_access.mode: allowlist`. Use `denied_domains` to override anything in the
  built-in dev allow list you do not want the agent to reach.

### Secrets and credentials

- Store every secret as an environment variable. Do not place API keys or webhook auth headers in
  `WORKFLOW.md` or `symphony.yml`; reference `$ENV_VAR` placeholders.
- Use separate API keys for the main agent and the quality gate so quotas and spend are
  independently observable and revocable.
- Rotate the Linear and provider keys on a schedule. Revoking a key is the fastest kill switch
  short of stopping the service.
- Avoid committing plaintext `.env` files. A secrets manager that injects environment variables at
  runtime keeps keys out of disk and Git history. For example,
  [1Password Environments](https://1password.com/blog/1password-environments-env-files-public-beta)
  (public beta) mounts a virtual `.env` over a UNIX pipe, so `LINEAR_API_KEY`, `ANTHROPIC_API_KEY`,
  and other keys are read on demand and never written to disk. `op run -- ./bin/symphony` and
  `direnv` are other common ways to load secrets without a checked-in file.

### Operations

- Watch provider dashboards for the first week after enabling the quality gate or learnings — both
  can produce sudden bursts.
- Pair `Pause Dispatch` with a deploy window or incident; in-flight agents continue, so a
  `mix symphony.stop ISSUE-ID` is the right tool for cutting an individual run.
- Periodically verify the audit chain (`mix symphony.audit ...` or `AuditLog.verify_file/1`),
  especially after host migrations or restores.
