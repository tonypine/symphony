# Run Symphony in Docker

A single image bundles Symphony plus both supported agent CLIs — Codex and Claude Code — so any
operator config that picks `agent.kind: codex` or `agent.kind: claude` will work out of the box.

## Requirements

- Docker Compose v2
- A `symphony.yml` operator config with paths written in container form (`/workspace/repos/<name>`)
- One or more host directories that contain repos to supervise, each with its own `WORKFLOW.md`
- The API keys your config needs (typically `LINEAR_API_KEY` plus agent credentials)

The agent CLIs read auth from `~/.codex` and `~/.claude` on your host — those directories are
bind-mounted into the container, so host logins and token refreshes are reused.

## Setup

```bash
cp docker/.env.example .env
# edit .env: set SYMPHONY_CONFIG, SYMPHONY_REPOS_ROOT, LINEAR_API_KEY
docker compose -f docker/docker-compose.yml up --build
```

Dashboard: <http://localhost:4000> (bound to loopback only).

`.env` lives at the repo root and is gitignored. Run the `docker compose` command from the repo
root so it gets picked up automatically.

## What gets mounted

| Source on host | Container path | Mode |
| --- | --- | --- |
| `$SYMPHONY_CONFIG` | `/workspace/symphony.yml` | ro |
| `$SYMPHONY_REPOS_ROOT` | `/workspace/repos` | rw |
| `~/.codex` | `/home/symphony/.codex` | rw |
| `~/.claude` | `/home/symphony/.claude` | rw |
| `~/.ssh` | `/home/symphony/.ssh` | ro |
| `symphony-logs` volume | `/workspace/logs` | rw |
| `symphony-state` volume | `/workspace/state` | rw |
| `symphony-workspaces` volume | `/workspace/workspaces` | rw |

Per-issue worktrees live in the `symphony-workspaces` named volume, not on your host, so they
won't clutter the filesystem you work from.

## Writing `symphony.yml` for the container

Every path inside the config must be a container path. If your host layout is:

```text
/Users/you/code/
  web/
    WORKFLOW.md
  mobile/
    WORKFLOW.md
```

then set `SYMPHONY_REPOS_ROOT=/Users/you/code` in `.env` and your config uses:

```yaml
workspace:
  root: /workspace/workspaces
  strategy: worktree
agent:
  kind: codex            # or: claude
  command: codex app-server
repos:
  - name: web
    workflow: WORKFLOW.md
    workspace:
      strategy: worktree
      repo: /workspace/repos/web
  - name: mobile
    workflow: WORKFLOW.md
    workspace:
      strategy: worktree
      repo: /workspace/repos/mobile
```

The folder name on the host must match `repos[].name` (so `/Users/you/code/web` → `repos[0].name: web`).

## Picking an agent

Switch agents by editing `symphony.yml`, not by rebuilding. Both CLIs are installed at fixed
versions (see `Dockerfile` build args).

- **Codex**: `agent.kind: codex`, `agent.command: codex app-server`. Reuses `~/.codex/auth.json`
  for ChatGPT auth, or set `OPENAI_API_KEY` in `.env`.
- **Claude Code**: `agent.kind: claude`, `agent.command: claude` (plus any flags). Reuses
  `~/.claude/.credentials.json` for Anthropic Console auth, or set `ANTHROPIC_API_KEY` in `.env`.
  Prefer pinning a Sonnet model (e.g. `agent.command: claude --model sonnet`) over Opus when
  available — Opus burns Agent-SDK credit much faster and Sonnet is usually sufficient for
  orchestration turns. Guidance only; revisit when Anthropic's model lineup or credit policy
  changes.

## Dashboard binding

Symphony refuses non-loopback binds unless `SYMPHONY_ALLOW_REMOTE_BIND=1`. The compose file sets
this so the container can bind `0.0.0.0:4000` and let Docker publish the port — but the host port
is bound to `127.0.0.1` only. Put authentication in front of it if you change that.

## Verification dev server

The image ships `bwrap` and `socat`, which run `verification.dev_server.start_cmd` in a sandbox
(see [Verification dev server runs in a sandbox](../docs/security.md#verification-dev-server-runs-in-a-sandbox)).
The dev server starts under the shipped compose file, which sets three `security_opt` entries
for `bwrap` and leaves the rest of the container's confinement as it is:

- `seccomp=seccomp-bwrap.json`: [`seccomp-bwrap.json`](seccomp-bwrap.json) is Docker's default
  seccomp profile (from [moby/profiles](https://github.com/moby/profiles/blob/main/seccomp/default.json))
  with one rule added, which lets a process without `CAP_SYS_ADMIN` call `clone` and `unshare`
  with namespace flags, `mount`, `umount2` and `pivot_root`. Docker's default profile refuses
  them, so `bwrap` can't make its namespaces. The kernel still checks each call: they only work
  inside the user namespace `bwrap` makes, never on the container's own mounts.
- `systempaths=unconfined`: Docker hides parts of `/proc` (such as `/proc/kcore`) behind mounts,
  and while they are there the kernel refuses `bwrap` a fresh `/proc`. Symphony runs as a
  non-root user with no capabilities, so the files they hid stay unreadable to it.
- `apparmor=unconfined`: on a host with AppArmor, Docker's `docker-default` profile denies every
  `mount`, `bwrap`'s included.

The container still runs as `symphony` with Docker's default capabilities, none of them
`CAP_SYS_ADMIN`, and is not `privileged`.

On a host that restricts unprivileged user namespaces through AppArmor (Ubuntu 23.10 and later),
also allow them on the host, or `bwrap` still fails:

```bash
sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0
```

Without these, `bwrap` can't make its namespaces and the dev server does not start: an agent run
with a dev server fails with `verification_failed` before its first turn, and an Auto Review
`web` pass is `blocked`. Remove the `security_opt` entries if you run no dev server and want
Docker's defaults back.

## Linux UID matching

On Linux, files written into bind-mounted repo paths inherit the container UID (`1000` by default).
Override before running so cleanup does not need `sudo`:

```bash
SYMPHONY_UID=$(id -u) SYMPHONY_GID=$(id -g) \
  docker compose -f docker/docker-compose.yml up --build
```

Docker Desktop on macOS handles UID mapping transparently — no override needed.

## Tear down

```bash
# stop, keep state
docker compose -f docker/docker-compose.yml down

# nuke named volumes too (loses workspaces, logs, runtime state)
docker compose -f docker/docker-compose.yml down -v
```

Note: `down -v` does NOT touch your bind-mounted `~/.codex` or `~/.claude` — those are host
directories, not Docker volumes.
