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
`bwrap` needs unprivileged user namespaces and `mount`, which Docker's defaults refuse, so under
the shipped compose file alone the dev server does not start: an agent run with a dev server fails
with `verification_failed` before its first turn, and an Auto Review `web` pass is `blocked`.
Nothing else is affected, and the container keeps Docker's default confinement.

To run the dev server, add the opt-in override
[`docker-compose.dev-server-sandbox.yml`](docker-compose.dev-server-sandbox.yml). On a host with
AppArmor (Ubuntu, Debian and most of their derivatives), first load the shipped AppArmor profile
[`apparmor-bwrap`](apparmor-bwrap), named `symphony-bwrap`, into the host's kernel:

```bash
sudo apparmor_parser -r -W docker/apparmor-bwrap
docker compose -f docker/docker-compose.yml -f docker/docker-compose.dev-server-sandbox.yml up --build
```

`apparmor_parser -r` loads the profile, or replaces it after you pull a changed one; `-W` also
caches it. The kernel forgets it at reboot, so to keep it loaded copy it where the host's AppArmor
service loads profiles at boot:

```bash
sudo cp docker/apparmor-bwrap /etc/apparmor.d/symphony-bwrap
sudo apparmor_parser -r -W /etc/apparmor.d/symphony-bwrap
```

Check it with `sudo aa-status | grep symphony-bwrap`. Without it, the container does not start:
Docker fails with `apparmor failed to apply profile`. On a host without AppArmor (Docker Desktop,
Fedora and other SELinux hosts) there is nothing to load: Docker ignores the AppArmor option. The
profile declares AppArmor ABI 3.0, as Docker's own does, so it needs AppArmor 3.0 or later
(Ubuntu 22.04, Debian 12).

Pass both `-f` files to every `docker compose` command for that deployment (`down` included). The
override sets three `security_opt` entries. They apply to **the whole container**, Symphony and
every agent and tool it runs, not only to `bwrap`:

- `seccomp=seccomp-bwrap.json`. **Loosens:** [`seccomp-bwrap.json`](seccomp-bwrap.json) is
  Docker's default seccomp profile (from [moby/profiles](https://github.com/moby/profiles/blob/main/seccomp/default.json))
  with one rule added, which lets any process without `CAP_SYS_ADMIN` call `clone` and `unshare`
  with namespace flags, `mount`, `umount2` and `pivot_root`. Any process in the container can then
  make user namespaces, which exposes more kernel code to it. The kernel still checks each call:
  mounts only work inside a user namespace the process made, never on the container's own mounts.
  **Buys:** `bwrap` can make its namespaces.
- `systempaths=unconfined`. **Loosens:** Docker stops hiding parts of `/proc` and `/sys` (such
  as `/proc/kcore`, `/proc/keys` and `/proc/timer_list`) and stops mounting `/proc/sys`,
  `/proc/irq` and `/proc/bus` read-only. Symphony runs as a non-root user with no
  `CAP_SYS_ADMIN`, so most of these stay unreadable or unwritable to it, but the kernel's own
  permissions are now the only guard. **Buys:** `bwrap` can mount a fresh `/proc`, which the
  kernel refuses while those mounts cover parts of the container's.
- `apparmor=symphony-bwrap`. **Loosens:** on a host with AppArmor, the container runs under
  `symphony-bwrap` instead of Docker's `docker-default` profile. It is `docker-default` (from
  [moby/profiles](https://github.com/moby/profiles/blob/main/apparmor/template.go)) with its
  `deny mount` rule replaced by rules that allow `mount` and `pivot_root`; every other rule,
  such as the denied writes to parts of `/proc` and `/sys`, still applies. As with seccomp, the
  kernel still keeps those mounts inside namespaces the process made. **Buys:** `bwrap`'s mounts.

The container still runs as `symphony` with Docker's default capabilities, none of them
`CAP_SYS_ADMIN`, and is not `privileged`. Leave the override out if you run no dev server.

A host that restricts unprivileged user namespaces through AppArmor (Ubuntu 23.10 and later) needs
no change: the restriction applies to unconfined processes, and `bwrap` in the container runs
under `symphony-bwrap`, whose ABI does not mediate user namespaces.

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
