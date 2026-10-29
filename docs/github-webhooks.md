# Instant GitHub updates

Turn on instant GitHub updates from Setup in the app. Symphony then hears from GitHub the moment a
pull request's checks finish, its head moves, it closes or its base branch moves, instead of
asking GitHub every `pull_requests.poll_interval_ms`. The steps below are the app's; the
[appendix](#appendix-headless-setup) sets the same thing up by hand on a Mac without the app.

## Turn them on

Open the Symphony window's **Setup** page. The **GitHub updates** card reads **Polling only**.
Click **Turn On Instant Updates…**: a sheet walks you through five steps, "Step 1 of 5" to "Step 5
of 5". Each step checks itself when you reach it and shows **Done**, **Checking…**, **Waiting**,
**To do** or **Failed** with what fixes it; **Continue** turns on once the step is done.

1. **Choose how GitHub reaches this Mac** (Relay). Pick a relay (see
   [Choosing a relay](#choosing-a-relay)); **GitHub CLI forwarding** is recommended and picked. A
   relay that needs a public address asks for it here.
2. **Check the GitHub CLI** (GitHub CLI). Symphony needs `gh` signed in with permission to manage
   webhooks (`admin:repo_hook`), and, for GitHub CLI forwarding, its forwarding extension, which
   Symphony installs. **Grant Permission…** (or **Sign In…**) opens Terminal on the right `gh`
   command; the row checks again every 3 seconds and when the app comes back to the front.
3. **Secret and port** (Secret and port). Symphony makes the webhook secret and the app keeps it in
   your Keychain (item `symphony-github-webhook`), never showing or logging it. Symphony's port is
   pinned so the relay can reach it; **Restart Symphony** shows only when the pinned port differs
   from the one Symphony listens on.
4. **Connect your repos** (Repos). Symphony starts forwarding each repository's updates, or adds a
   webhook to it, which needs admin access to the repository. A repository that fails has
   **Retry** and **Leave on Polling**.
5. **Send a test update** (Test). Symphony asks GitHub for one update from each connected
   repository and checks that it arrives and passes the secret check ("Received and verified").
   **Done** works with some repositories left on polling.

The card then reads **Instant** and lists each repository with its last update. **Finish Setup…**
opens the same sheet with the done steps ticked, when a step is still to do. A `symphony.yml`
brought from another Mac with instant updates on reads **Needs setup on this Mac** until the sheet
runs here.

With instant updates on, **Add Repo** gains a last step, **Instant updates for <repo>**: it connects
the new repository and sends it a test update. **Skip** leaves that repository on polling.

## Choosing a relay

Symphony listens on `127.0.0.1`, which GitHub can't reach. A relay receives the deliveries on the
internet and forwards them to `http://127.0.0.1:<dashboard port>/api/v1/github/webhook`. The first
step of the sheet offers four:

| Relay | `relay:` | Choose it when |
| --- | --- | --- |
| **GitHub CLI forwarding** (recommended) | `gh_webhook_forward` | You want nothing to sign up for: Symphony runs `gh webhook forward` for each repository with your GitHub CLI and restarts it when it stops. GitHub lets one person forward a repository at a time, and the secret shows in the relay's command line (see [The secret](#the-secret)). |
| **smee.io** | `smee` | You want a free public URL with no account. Anyone with the channel URL can read the deliveries, so keep it private. |
| **Cloudflare Tunnel** | `cloudflare_tunnel` | You have a Cloudflare account and a domain. The most reliable. |
| **Tailscale Funnel** | `tailscale_funnel` | You have a Tailscale account: it serves Symphony's port on a public `ts.net` name. |

With smee.io, Cloudflare Tunnel or Tailscale Funnel you run the relay yourself (see
[Start a relay](#4-start-a-relay)) and paste its public URL in the first step; Symphony then adds a
webhook pointing at it to each repository. **Change Relay…** under the card's Details switches
relays later: what the old relay connected is removed and each repository connects again through
the new one, while Symphony keeps polling.

## What changes once they are on

Symphony's PR and CI watcher reads each watched pull request about once per
`pull_requests.poll_interval_ms`. With `github.webhooks` on, GitHub also tells Symphony when a check
suite, check run or workflow run finishes, when a pull request's head moves or the PR closes, and
when a branch moves. The watcher patches what it knows of that PR (its state API shows
`watch.source: webhook`) and reads it 3 seconds later, so a green head lands, or a red one goes to
the fix run, within seconds. Only that read decides, as the timed poll does: one passing check
never makes a head green by itself.

A push to a base branch (or a pull request that closes by merging into it) can make every other PR
on it fall behind or conflict. The watcher marks each open watched PR on that base as of unknown
mergeability and reads them one by one, 1 second apart, while GitHub computes it again: a PR that
now conflicts goes to CI Fix in seconds, or waits on the PR ahead of it that changes the same files,
and a PR that is now `BEHIND`, in any phase, gets its update-branch from the branch upkeep (U1 in
the [decision table](pr-ci-decisions.md#upkeep)) unless a run is working on it or a PR ahead of it
changes the same files; a PR whose run is working is updated on the read that sees the run end. A
read that finds a conflict, a PR waiting on its competitors, or a `BEHIND` PR that last waited on a
PR ahead of it, reads every watched PR and the repository's open PRs too, as the timed poll does, so
the landing of the PR ahead clears the wait in seconds as well: the conflict gets its CI Fix run,
and the `BEHIND` PR its update-branch, on its own read.

A `release` published on `tonypine/symphony`, the repository the macOS app updates from, records its
newest release in Symphony. `/api/v1/state` reports it under `app_update.latest_release`, and the app
checks for the update on its next status poll instead of waiting for its own timer.

Webhooks change how soon Symphony acts, never what it does. The timed poll keeps running and
catches up on any delivery lost while the Mac sleeps, Symphony restarts or the relay drops. While
deliveries are healthy it is only a safety net, every `github.webhooks.fallback_poll_interval_ms`
(5 minutes). When a read finds a change no delivery reported, the deliveries count as unhealthy and
the watcher polls every `pull_requests.poll_interval_ms` again until the next one arrives. It
polls at that interval too while the repository's `gh webhook forward` keeps stopping (below).

Every delivery is checked against the hook's secret (`X-Hub-Signature-256`). One that does not
verify gets `401` and a log line naming its delivery id, event and reason, never the payload.

## Health

The **GitHub updates** card says in a word what reaches Symphony now:

| Card reads | What it means | What to do |
| --- | --- | --- |
| **Polling only** | Instant updates are off; Symphony checks GitHub every poll interval. | **Turn On Instant Updates…** |
| **Needs setup on this Mac** | `symphony.yml` turns them on, but this Mac never ran the setup. | **Finish Setup…** |
| **Setting up** | Some steps are still to do; Symphony polls until they are. | **Finish Setup…** |
| **Instant** | GitHub's updates arrive at once; Symphony still polls every `fallback_poll_interval_ms` as a safety net. | Nothing. |
| **Polling while the relay is down** / **Polling while GitHub is quiet** | A relay can't restart or keeps stopping, or a repository heard nothing for `silence_alert_minutes` after a read found a change no delivery reported. Symphony polls every poll interval until updates arrive again. | **Restart Relay** (GitHub CLI forwarding). |
| **Secret check failing** | Deliveries fail the secret check, or this Mac has no secret. Symphony refuses them and polls. | **Re-create Secret…** |

A row also shows when GitHub's request limit runs low or is used up. The Overview page lists a
Needs attention row while the relay is down or the secret check fails. Under **Details**: the
relay, the secret, **Safety-net check every** (`fallback_poll_interval_ms`), **Warn me after no
updates for** (`silence_alert_minutes`), the events received and the address. The two intervals
are also in Settings, under **GitHub updates**.

In the API, `GET /api/v1/setup` → `github_updates` has `mode` (`off`, `needs_setup`, `setting_up`, `on`,
`degraded`), each step and each repository, with why a repository is degraded
(`degraded_reason`) and how often its watcher polls now (`poll_interval_ms`).

Symphony restarts a `gh webhook forward` that stops: when its connection to GitHub drops, the
extension retries three times, 5 seconds apart, then exits ("unable to connect to webhooks server,
forwarding stopped"). Symphony starts it again after 1 second, doubling the wait up to 5 minutes
while it keeps failing, and the section counts the restarts and shows the last error. `gh` prints
its usage text after the error that stopped it, so the error shown is the first of its last 20
output lines that reads as one (`error`, `failed`, `unable to`), else the line before the usage
text, else its exit status, or the signal that killed it (`gh webhook forward was killed by signal
9`); the log has all 20 lines, once per stop. A relay that stopped more than twice in ten
minutes reads `stable: false` until it has run ten minutes without a stop: meanwhile its
repository is `degraded` and its watcher polls every `pull_requests.poll_interval_ms`. A second
`gh webhook forward` on the same repository fails with `Hook already exists`.

## Turning them off

**Turn Off…** asks first ("Turn off instant GitHub updates?"): Symphony stops the relays it runs,
removes only the webhooks it added and goes on checking GitHub every poll interval, so tickets react
within a minute instead of seconds. The secret stays in your Keychain and webhooks you added
yourself stay on GitHub; **Turn On Instant Updates…** sets them up again. It writes
`github.webhooks.enabled: false`.

**Re-create Secret…** makes a new secret, saves it in your Keychain and connects every repository
again with it; updates signed with the old secret are refused from then on.

## The secret

`gh webhook forward` takes the secret only as its `--secret` argument: it reads no environment
variable and no standard input for it. So while a relay runs, any process on this Mac can read
the secret in its command line (`ps`). Symphony keeps it out of its own logs, its API and
`symphony.yml`, and a URL relay's hooks get it from a file only Symphony can read. When other
people sign in to this Mac, use a URL relay, or re-create the secret after they could have seen it.

## Appendix: headless setup

### The setup API

Symphony runs every step of the app's sheet itself, behind its API, so `curl` can drive it too:

```sh
curl -s localhost:4040/api/v1/setup | jq .github_updates          # mode, steps, repos
curl -X POST localhost:4040/api/v1/setup/github_updates/turn_on -d '{"relay":"gh_webhook_forward"}'
curl -X POST localhost:4040/api/v1/setup/github_updates/run_step -d '{"step":"secret"}'
curl -X POST localhost:4040/api/v1/setup/github_updates/test
curl -X POST localhost:4040/api/v1/setup/github_updates/turn_off
```

The other actions are the card's and the sheet's buttons: `leave_on_polling` (a repository's
**Leave on Polling**), `restart_relay`, `recreate_secret` and `change_relay`.

| Step | Done when | What running it does |
| --- | --- | --- |
| `relay` | `gh`'s webhook extension is installed, or a URL relay's public URL is known | installs `cli/gh-webhook`, or keeps the `url` given |
| `gh_ready` | `gh` is signed in with the `admin:repo_hook` scope | checks again (signing in is yours: `gh auth refresh -h github.com -s admin:repo_hook`) |
| `secret` | a webhook secret is set | makes one, hands it to the app (secret `symphony-github-webhook`, passed as `SYMPHONY_GITHUB_WEBHOOK_SECRET`) and writes `secret: $SYMPHONY_GITHUB_WEBHOOK_SECRET` |
| `port` | `dashboard.port` is pinned to the port Symphony listens on | pins it |
| `repo:<key>` | the repository's relay runs, or its hook exists | checks admin access, then starts `gh webhook forward` or adds the hook with `gh api repos/:repo/hooks` |
| `test:<key>` | a delivery from the repository verified after the test | starts the relay again (GitHub pings the new hook) or pings the hook; it fails after 30 s |

A failed step says what is wrong and how to fix it, and a repository whose step fails (no admin
access, say) stays on polling while the others connect. `mode` is `on` once every connected
repository's test verified, and `degraded` while a relay can't restart or keeps stopping, or a
repository heard nothing for `silence_alert_minutes` after a read found a change no delivery
reported. Each repository says why it is degraded (`degraded_reason`) and how often its watcher
polls now (`poll_interval_ms`). A
`symphony.yml` brought from another Mac with webhooks on reads `needs_setup` until the setup runs
on this Mac. Turning off stops the relays, deletes only the hooks Symphony created and keeps the
secret.

### By hand

On a Mac where Symphony can't run the steps either, set instant updates up step by step.

### 1. Pin the dashboard port

The relay needs a fixed address. In `symphony.yml`:

```yaml
dashboard:
  port: 4040
```

### 2. Create the secret

Keep it in the Keychain and pass it to Symphony in an environment variable:

```sh
security add-generic-password -a "$USER" -s symphony-github-webhook -w "$(openssl rand -hex 32)"
export GITHUB_WEBHOOK_SECRET="$(security find-generic-password -a "$USER" -s symphony-github-webhook -w)"
```

Or write it to the state folder, where Symphony reads it when `github.webhooks.secret` is unset:

```sh
STATE_ROOT="$HOME/Library/Application Support/symphony"   # or $SYMPHONY_STATE_ROOT
openssl rand -hex 32 > "$STATE_ROOT/github_webhook_secret"
chmod 600 "$STATE_ROOT/github_webhook_secret"
```

A release build keeps its state one level down, in `.../symphony/release`.

### 3. Turn webhooks on

```yaml
github:
  webhooks:
    enabled: true
    relay: smee
    secret: $GITHUB_WEBHOOK_SECRET   # leave out to use <state-root>/github_webhook_secret
    # events: [check_suite, check_run, workflow_run, pull_request, push, release]
    # fallback_poll_interval_ms: 300000   # the safety-net poll while deliveries are healthy
    # silence_alert_minutes: 10           # warn after this long without a delivery
```

The app's Settings window has both intervals under **GitHub updates**.

Restart Symphony. The app's **GitHub updates** card in Setup reads **Instant** once a delivery verified.

### 4. Start a relay

#### smee.io

1. Open <https://smee.io/new> and copy the channel URL.
2. Run the client (keep it running, for example with `launchd` or in a `tmux` pane):

   ```sh
   npx smee-client --url https://smee.io/<channel> --target http://127.0.0.1:4040/api/v1/github/webhook
   ```

#### Cloudflare Tunnel

```sh
brew install cloudflared
cloudflared tunnel login
cloudflared tunnel create symphony
cloudflared tunnel route dns symphony symphony-hooks.example.com
cloudflared tunnel run --url http://127.0.0.1:4040 symphony
```

The payload URL is `https://symphony-hooks.example.com/api/v1/github/webhook`. Add a Cloudflare
Access bypass rule for that one path if the hostname is behind Access.

#### `gh webhook forward`

```sh
gh extension install cli/gh-webhook
gh webhook forward --repo <owner>/<repo> \
  --events check_suite,check_run,workflow_run,pull_request,push,release \
  --secret "$GITHUB_WEBHOOK_SECRET" \
  --url http://127.0.0.1:4040/api/v1/github/webhook
```

This creates the hook itself, so skip step 5. The hook lasts only while the command runs.

### 5. Add the webhook on GitHub

In the repository's **Settings → Webhooks → Add webhook**:

- **Payload URL**: the smee channel URL or the tunnel URL above.
- **Content type**: `application/json`.
- **Secret**: the value from step 2.
- **Events**: "Let me select individual events", then **Check suites**, **Check runs**,
  **Workflow runs**, **Pull requests**, **Pushes** and **Releases**.

GitHub sends a `ping` when the hook is saved. Symphony answers it by reading every watched PR at once,
which also catches up on anything missed. `gh webhook forward` creates the hook, and so sends a
`ping`, every time it starts.

### Checking it works

- The **GitHub updates** card lists each repository with its last update, and `curl -s
  localhost:4040/api/v1/setup | jq .github_updates` shows each repository's last delivery.
- A log line `PR watch found a change no GitHub delivery reported` names the PR and the change a
  read found that no delivery did; the watcher then polls at the poll interval until the next
  delivery arrives.
- GitHub's **Recent Deliveries** tab shows Symphony's answer: `202` when accepted, `401` for a bad
  signature, `404` while `github.webhooks.enabled` is off, `503` while the PR watcher isn't running
  (`pull_requests` polling off).
