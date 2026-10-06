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
On macOS, a sandboxed process's Foundation stages every atomic file write in the per-user
`TemporaryItems` dir (`$(getconf DARWIN_USER_TEMP_DIR)TemporaryItems`), so `swift build` and
`swift test` fail in an agent's sandbox. That dir can't be granted: macOS refuses to read it, so
Claude Code withholds an `allowWrite` entry for it (`withheld allowWrite …/TemporaryItems: its
link chain cannot be followed safely` in its debug log). Instead, a local Claude session's env
holds `DIRHELPER_USER_DIR_SUFFIX=symphony/none`, a suffix libc rejects: the per-user temp dir
then falls back to the session's `$TMPDIR`, and Foundation stages each atomic write beside the
file it replaces, where the agent may already write. The per-user cache dir has no value then
either, so `SWIFTPM_MODULECACHE_OVERRIDE` points SwiftPM's module cache at the run's temp folder.
The per-user temp dir stays read-only: Symphony keeps each session's Claude settings and the MCP
shim there.

Both runtimes also deny writes to the workspace's own instructions and workflow files:
`WORKFLOW.md`, `symphony.yml`, the project `.claude/` settings, agents, commands and hooks, and the
skill directories `.ai/skills`, `.claude/skills` and `.codex/skills`. In a local workspace the deny
also covers the files a symlink in one of those points at: Symphony's own `.ai/skills/pull` links
to `priv/skills/pull`, so `priv/skills/pull` is read-only to the agent. An SSH worker's workspace
gets the plain list.

The sandbox binds only the commands an agent runs. Claude's file tools (`Edit`, `Write`,
`NotebookEdit`) run in the Claude process itself, so each Claude session's settings also carry an
`Edit(<path>)` deny rule for every one of those paths and every symlink target. Claude Code applies
an `Edit` rule to all three tools, and still applies it under `--dangerously-skip-permissions`.
It checks a symlink's real path, which is why the targets need their own rules.

Each layer covers a different way to write one of those paths:

| Write | Refused by |
| --- | --- |
| A shell command (`sed -i`, `git merge`, a script) | The sandbox: Claude's `sandbox.filesystem.denyWrite`, Codex's filesystem permissions |
| Claude's `Edit`, `Write` or `NotebookEdit` | `Edit(<path>)` rules in the session's `permissions.deny` |
| Codex's `apply_patch` | Codex's filesystem permissions, if `apply_patch` runs under them; not yet checked with a real session ([TP-530](https://linear.app/tonypine/issue/TP-530)) |
| A branch pushed with `github_push_branch`, or merged with `github_sync_base` | The tools, which refuse a branch that changes one of the paths |
| A `git push` from the agent's shell | Claude's `Bash(git push:*)` deny rule, then CI |
| A pull request that changes one of the paths | The `protected-paths` CI job, until a person waives it |

The first three stop the write in the workspace, so a later session there can't load it. The others
only stop the change from reaching the base branch.

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
so after approving, re-run the job. Bots count for neither. Since no agent can clear this check,
Symphony's CI poller dispatches no CI-fix run and spends no fix attempt while it is the only red
check; the issue waits for the waiver. The workflow tells Symphony's pull requests apart only by
the `auto/` branch prefix. So it skips the case where a person's own open pull request on another
branch is attached to the issue, and Symphony keeps working on that branch.

Every local agent may also write one per-user cache folder, `~/Library/Caches/symphony/agent` on
macOS, which holds its Hex home, its `elixir_make` cache and Dialyxir's core PLTs (see
`permissions.filesystem.allow_write_paths` in [configuration](configuration.md)). Runs share it,
so one run can change what a later run reads: Hex checks each package tarball against the checksums
in `mix.lock`, and `elixir_make` checks each precompiled archive against the package's checksum
file, before using it. The host's own `~/.hex` and `~/Library/Caches` stay read-only, and the
folder never holds `hex.config`, which can hold Hex API and repo keys.

### Git metadata

A local agent commits in its workspace, so it may write the workspace's git dir and, for a
worktree (`workspace.strategy: worktree`), the shared repo's `.git`. Some files there change what
git runs, in the agent's own `git` commands and in Symphony's on the host: the config (filter
drivers, `core.fsmonitor`, `core.hooksPath`), the hooks and `info/attributes`. In each of those git
dirs, every local runtime denies writes to:

- `config`, `config.worktree`, `hooks`, `info` and `packed-refs`,
- every worktree's `worktrees/<id>/config` and `worktrees/<id>/config.worktree`,
- every submodule's `modules/<name>/config`, at any depth.

Objects and refs stay writable, so `git add`, `git commit` and `git fetch` work. In a worktree
those objects land in the shared `<repo>/.git/objects` and outlive the workspace until git
collects them.

| Runtime | How the git metadata is write-protected |
| --- | --- |
| Claude | `sandbox.filesystem.denyWrite` entries, globs for the worktree and submodule files, and an `Edit` rule for each one, which refuses the file tools too. Claude Code itself lets a worktree's session write the shared `.git` and protects only its `config`, the session's own `config.worktree` and `hooks`. |
| Codex with SRT | SRT `denyWrite` entries, globs for the worktree and submodule files. |
| Native Codex | A read-only entry for each path in the managed permission profile. The profile takes literal paths, so the worktree and submodule globs become the files that exist when the session starts. Codex itself protects a `.git` inside each writable root, but not the git dirs Symphony adds as writable roots. Codex may drop the profile's entries (see [configuration](configuration.md)), so use SRT when they must hold. |

An SSH worker's workspace gets none of these entries: its git dirs aren't on this host. Its
workspace `.git` stays write-protected with the other protected paths.

### Workspace hooks run outside the sandbox

A repository's `hooks` run on the host (or the SSH worker) as the operator, outside the agent
sandbox: they can reach the Keychain, SSH keys and the tokens in Symphony's environment. Symphony
reads the hook scripts from the `WORKFLOW.md` committed on the fetched base branch, never from
the agent's checkout. But a hook that runs the repo's build tool (`mix`, `npm`, `gradle`, `make`)
runs whatever code the checkout holds: any `mix` command evaluates `mix.exs`, and
`mix deps.compile` runs the dependencies' build scripts.

- **`after_create` in a worktree runs on the base branch's tree,** on this machine and on an SSH
  worker. A worktree can be created on a branch an agent already pushed to: a rework or PR run
  checks out the PR head, and a removed workspace is made again on its existing `auto/<issue>`
  branch. So Symphony detaches the worktree at the base commit (the repository's `base_branch`, else a `workspace.source` clone's
  `origin/HEAD`, else the source repo's `HEAD`; on an SSH worker, `origin/<base_branch>`, else the
  worker repo's `HEAD`), runs the hook, and checks the branch out again, with repo hooks off. Before the hook, Symphony removes the ignored
  files in the worktree (`git clean -ffdx`), so a reused worktree's hook never loads the `deps/` or
  `_build/` an agent wrote there. A worktree with uncommitted changes, or one whose base commit
  can't be resolved, skips the hook with a warning and keeps its pending marker. The
  hook installs the base branch's dependencies, so a branch that changes its lock file runs on
  them until the agent fetches its own.
- **`after_create` in a `clone`-strategy workspace** runs on whatever the workspace holds. A hook
  that clones the repo itself should install dependencies before it checks out an agent's branch.
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
| `before_remove` | `cd /`, then `gh pr list` and `gh pr close` on `SYMPHONY_REPO` and `SYMPHONY_BRANCH` | Closes the branch's open pull requests with the operator's `gh` login. It runs nothing from the agent's checkout: Symphony sets both variables itself, and the step leaves the checkout before calling `gh`. |

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

**Git write model.** SRT denies writes to the git config files on every git dir the agent may
write; see [Git metadata](#git-metadata) for the list and for the other runtimes.

**Known issue.** Codex app-server sessions wrapped by SRT can fail while writing stdout with
`Resource temporarily unavailable (os error 35)`, surfaced by Symphony as
`:codex_stdio_write_failed`. Symphony drains and compacts app-server output after receipt, but this
failure occurs before the frame reaches Symphony. Disable SRT for Codex on stability-sensitive runs
until the Codex/SRT stdio behavior is hardened.

### Host-side git

Symphony runs git on the host, outside every agent sandbox and as the operator, to create, reuse
and back up worktrees and to read branches for reviews and gates. Agents commit in the shared repo,
so its local config (`.git/config`, a `config.worktree`, and the files they include) is where an
agent would put a command for that git to run, and a branch's `.gitattributes` picks which files
the command runs on. Every host-side git call:

- reads no global or system config (`GIT_CONFIG_GLOBAL` and `GIT_CONFIG_SYSTEM` are `/dev/null`)
  and runs no hook, file-system monitor or credential helper, nor an `ext::` or `git://` remote;
- runs no `core.askPass` when an HTTPS remote asks for credentials git doesn't have
  (`-c core.askPass=`), and doesn't prompt on a terminal either (`GIT_TERMINAL_PROMPT=0`), so the
  call fails instead. The empty `core.askPass` also turns off git's `SSH_ASKPASS` fallback; an
  askpass the operator sets in `GIT_ASKPASS` still runs, since git reads it before the config;
- still reads the repo's local config, which holds the remotes and branches Symphony works with.
  Before a command that can read or write work-tree files (anything but `rev-parse`, `fetch`,
  `log`, `show` and a few other read-only commands), Symphony lists the filter drivers
  (`filter.<name>.clean`, `.smudge` and `.process`) and merge drivers (`merge.<name>.driver`)
  defined in that config and in every file it includes, whatever the include's condition. It
  blanks each filter driver with `-c` and sets its `required` to `false`, so git writes and reads
  files as the repo stores them. In a repo that uses Git LFS the worktree gets the pointer files,
  and an agent that needs the content runs `git lfs pull` in its sandbox. It replaces each merge
  driver with `git merge-file`, so `merge` (the acceptance gate, `github_sync_base`) merges those
  files as git does when no driver is set, conflict markers included;
- doesn't run, and returns an error, when that config can't be read or names a driver with `=` in
  its name, which `-c` can't address;
- runs `diff`, `log`, `show`, `whatchanged`, `blame` and `format-patch` with
  `--no-ext-diff --no-textconv`, so the diffs of reviews, the acceptance gate and the auto-merge
  fingerprint run no `diff.external`, `diff.<name>.command` or `diff.<name>.textconv`, and show
  the files as the repo stores them. `diff-tree`, `diff-index` and `diff-files` run a diff driver
  only when asked to. It refuses `range-diff`, which runs the textconv drivers whatever options it
  gets. A test fails when code under `lib/` starts git without these options;
- runs `fetch`, `ls-remote` and `pull` with `--upload-pack=git-upload-pack` and `push` with
  `--receive-pack=git-receive-pack`: the config's `remote.<name>.uploadpack` and `.receivepack`
  would run as the operator for a remote on the same machine, and a `-c` can't override them.
  `core.alternateRefsCommand=true` keeps a fetch from running the config's command for an
  alternate object store;
- checks and makes no signature: `log.showSignature`, `merge.verifySignatures` and `push.gpgSign`
  are off, so the config's `gpg.program` doesn't run on a commit an agent signed;
- leaves nested repos alone: a nested repo in a workspace keeps its own config, which the agent
  writes. `diff.ignoreSubmodules=dirty` keeps `status` from running git inside one,
  `submodule.recurse=false` keeps `checkout` and `reset` out, and the orphan backup's `add -A`
  starts from an empty index.

Host-side git still honors these keys of the repo's local config that can lead it to run a command:

- `remote.<name>.url`, `.pushurl`, `.vcs` and `url.<base>.insteadOf` (or `.pushInsteadOf`) can
  point a fetch or push at another repo. A `<helper>::<address>` URL runs `git-remote-<helper>`,
  which git looks up in its own folder and on `PATH`, not in the repo.
- `gpg.program` (and `gpg.<format>.program`, `gpg.ssh.defaultKeyCommand`) runs only when git signs
  or checks a signature, which host-side git doesn't do (see above).
- `core.editor`, `sequence.editor`, `core.pager` and `pager.<command>` run only when git talks to a
  terminal, which Symphony's git never does.

On an SSH worker, the scripts Symphony runs over SSH to fetch, create, reuse, back up and remove a
worktree, to put a worktree on the base branch for `after_create`, and to read the review agent's
diff of a workspace, run git as the worker's operator account with the same protections. They
define a `symphony_git` shell function that sets the same environment and `-c` overrides, and
lists and blanks the filter drivers in the worker repo's `config`, its `config.worktree` and
every file they include before each command that can read or write work-tree files, and refuses
`range-diff`. It also
refuses to run git when an include path holds a newline, since the shell reads the list line by
line. Their `fetch origin` gets `--upload-pack=git-upload-pack` as on the host, and the review
agent's `diff`, `log` and `show` get `--no-ext-diff --no-textconv`. They replace no merge driver: they never merge.

Limits:

- The drivers are listed just before the command runs, so one written to the config in between
  still runs. Every local runtime denies agent writes to the repo's config files (see the Git
  write model above), but native Codex may drop those entries.
- A command that prints a diff through another git command, such as `stash show -p` or
  `add -p`, gets neither option. Symphony runs none of them on the host or a worker.

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

### Verification dev server runs in a sandbox

Symphony starts `verification.dev_server.start_cmd` itself, from the checkout under test:

- in an agent run, from the agent's own workspace, before the first turn and for the whole run;
- in an Auto Review `web` pass, from a second worktree at the PR head.

The command usually runs files from that checkout: a script such as Symphony's own
`scripts/qa-dashboard-server.sh`, and the repo's build tool (`mix`, `npm`, `pnpm`), which runs the
project's code and build config. The agent can change all of these, so Symphony runs the command
under macOS Seatbelt (`sandbox-exec`), or bubblewrap (`bwrap`) on Linux, with limits like the
agent's sandbox:

- **Reads.** The credential and config stores the agent can't read are denied too (`~/.ssh`,
  `~/.aws`, `~/.config/gh`, the keychains, shell startup and history files, and the rest of the
  read-deny list in [Sandbox defaults](#sandbox-defaults-for-the-agent-process)), and so are
  the Codex files a Codex agent can't read (`~/.codex/auth.json`, `~/.codex/config.toml`) and
  every per-run `CODEX_HOME` Symphony writes for a Codex agent.
  `workspace.sandbox.allow_read_paths` does not apply to it.
- **Writes.** Only the checkout, a temp folder of its own (`$TMPDIR`, removed when the server
  stops), the agent cache folder, the per-user `TemporaryItems` dir (macOS) and the `/dev` sinks
  are writable. Inside the checkout, the paths the agent may not write stay read-only: `.git`,
  `WORKFLOW.md`, the skills and the other agent-protected paths.
- **Network.** The server may listen and connect on loopback only, so it can't serve on another
  interface. It reaches the dependency hosts through a proxy on loopback that Symphony runs for
  it (`HTTPS_PROXY` and `HTTP_PROXY`): the proxy only tunnels HTTPS (`CONNECT`) to the agent's
  built-in dependency hosts plus `agent.permissions.network.allowed_domains`, less
  `denied_domains`, and to none with `mode: block`. The model provider hosts are left out. Any
  other host gets a 403.
- **Processes outside the sandbox** (macOS). A process launchd starts is not in the sandbox, so the
  ways to ask it for one are denied: Apple Events (`osascript -e 'tell application "Terminal"
  to do script ...'`), LaunchServices (`open -a Terminal x.command`) and launchd jobs
  (`launchctl submit`). `/usr/bin/open`, `/usr/bin/osascript` and `/bin/launchctl` can't run at
  all.
- **Other processes** (macOS). The server may look into and signal only processes in its own
  sandbox (`process-info*` and `signal` limited to `same-sandbox`). So `ps eww` can't read the
  environment of Symphony's BEAM or any other process outside it, and `kill` can't stop them.
- **Mach services** (macOS). Like the agent profiles, the server may look up only a fixed list of mach
  services: the agent's list without its window, font, sound, power and LaunchServices services,
  plus `trustd`, which checks TLS certificates for tools that use Security.framework. So there
  is no window server (`com.apple.windowserver.active`), and a program from the checkout can't
  draw windows or dialogs on the operator's desktop. There is no pasteboard either, so `pbpaste`
  can't read the operator's clipboard. The keychain daemon (`com.apple.SecurityServer`) stays on
  the list, as it does for agents: `mix` reads the system's root certificates through it.
  The list is derived from a record of the agent profiles' list
  (`DevServerSandbox.mach_services/0`), and the `agent-profile` workflow checks that record
  against the latest SRT release every week, so the two don't drift apart.
- **Environment.** The server gets the agent's environment, not the operator's: no
  `LINEAR_API_KEY`, provider keys, GitHub tokens or `SSH_AUTH_SOCK`. Hex and `elixir_make` use
  the agent cache folder.

On macOS loopback stays open, so the server can still reach other services on the host's
loopback, such as Symphony's own dashboard and API, which have no authentication (see
[Local-only dashboard bind](#local-only-dashboard-bind)).

On Linux, `bwrap` builds the same limits from mounts and namespaces:

- **Reads.** The whole filesystem is mounted read-only. Each denied folder is covered by an empty
  one and each denied file by `/dev/null`. `/tmp`, `/run` and the folder of the per-run
  `CODEX_HOME`s are empty, so the server sees no other run's temp folder and no X11, D-Bus or
  Docker socket; `/dev` and `/proc` are its own.
- **Writes.** The checkout, its `$TMPDIR` and the agent cache folder are mounted writable again,
  and the protected paths read-only over them. A protected path that doesn't exist yet can't be
  mounted over, so its nearest folder inside the checkout is read-only instead (all of `.claude`
  when `.claude/settings.local.json` is missing), and a missing top-level folder (`.claude`,
  `.ai`, `.codex`, `config`) gets an empty read-only placeholder while the server runs, removed
  when it stops. A missing top-level file (`WORKFLOW.md`, `symphony.yml`, `mise.toml`,
  `.tool-versions`) is not blocked, since its placeholder would be an empty file in the agent's
  `git status` for the whole run; the server can create it, and the protected paths check on
  the pull request catches it if it's committed.
- **Network.** The server gets a network namespace of its own with only a loopback interface,
  so it can't reach any other address at all. `socat` bridges two ports over unix sockets in its
  `$TMPDIR`: its own port, from the host's `127.0.0.1` to the sandbox's (so it must listen on
  `127.0.0.1`, not only on `::1`), and the egress proxy's, from the sandbox's loopback to the
  host's. Other services on the host's loopback, such as Symphony's dashboard, are out of reach.
  There is no DNS inside: names are resolved by the proxy.
- **Processes outside the sandbox.** The server runs in its own pid, IPC and user namespaces and
  sees no D-Bus or Docker socket, so it can't have `systemd-run` or a container start a process
  for it. Unlike under Seatbelt, a unix socket elsewhere on the filesystem (outside `/tmp`,
  `/run` and the denied paths) stays reachable.

The dev server does not start on other systems; on macOS when `/usr/bin/sandbox-exec` is missing;
and on Linux when `bwrap` or `socat` is not on `PATH`, or `bwrap` can't make its namespaces (no
unprivileged user namespaces, or Docker's default seccomp profile, see
[docker/README.md](../docker/README.md#verification-dev-server)). An agent run then fails with
`verification_failed` before its first turn, and an Auto Review `web` pass is `blocked`.

Not every macOS version keeps the listener on loopback: on macOS 15 the rule that lets the server
accept connections on loopback also lets it bind `0.0.0.0` and the LAN address. So before the
first dev server starts, Symphony binds `0.0.0.0` under the profile with `/usr/bin/perl`, and
unless Seatbelt refuses it the dev server does not start either
(`dev_server_sandbox_unconfined`), the same way. The result holds until Symphony restarts.

The dev server is off by default. It starts only when `verification.enabled` is `true` and
`verification.dev_server.start_cmd` is set. A repo's `WORKFLOW.md` can set both, and its values
override `symphony.yml`. To turn it off, leave `verification.enabled` unset (or `false`) in
`symphony.yml` and in every repo's `WORKFLOW.md`, or remove `start_cmd` from them. Without a dev
server, Auto Review skips the `web` playbook ("needs `verification.dev_server`").

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
- `verification.enabled` runs the checkout's code as your user, inside a sandbox like the
  agent's (Seatbelt on macOS, `bwrap` on Linux; see
  [Verification dev server runs in a sandbox](#verification-dev-server-runs-in-a-sandbox)). On
  macOS, like the agent, it can still reach services on the host's loopback, so keep the
  dashboard's API on a host where that is acceptable.

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
