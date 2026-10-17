# GitHub webhooks on macOS

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
now conflicts goes to CI Fix in seconds, and a `Merging` PR that is now `BEHIND` gets its
update-branch. A PR still in Code Review, QA or Rework is left behind on purpose: a review or QA run
starts only on a green head, so updating it on every merge would keep restarting its CI, and an
agent run brings its own branch up to date. It is updated once it reaches `Merging`.

A `release` published on `tonypine/symphony`, the repository the macOS app updates from, records its
newest release in Symphony.

Webhooks change how soon Symphony acts, never what it does. The timed poll keeps running and
catches up on any delivery lost while the Mac sleeps, Symphony restarts or the relay drops. While
deliveries are healthy it is only a safety net, every `github.webhooks.fallback_poll_interval_ms`
(5 minutes). When a read finds a change no delivery reported, the deliveries count as unhealthy and
the watcher polls every `pull_requests.poll_interval_ms` again until the next one arrives.

## How deliveries reach Symphony

Symphony listens on `127.0.0.1`, which GitHub can't reach. A relay receives the deliveries on the
internet and forwards them to `http://127.0.0.1:<dashboard port>/api/v1/github/webhook`:

| Relay | `relay:` | Notes |
| --- | --- | --- |
| [smee.io](https://smee.io) | `smee` | Free, no account. Anyone with the channel URL can read the deliveries, so keep it private. |
| [Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/) | `cloudflare_tunnel` | Needs a Cloudflare account and a domain. Most reliable. |
| [Tailscale Funnel](https://tailscale.com/kb/1223/funnel) | `tailscale_funnel` | Needs a Tailscale account. Serves Symphony's port on a public `ts.net` name. |
| `gh webhook forward` | `gh_webhook_forward` | The default when Symphony sets it up. Needs the `gh` webhook extension, which Symphony installs. GitHub lets one person forward a repository at a time. |

Every delivery is checked against the hook's secret (`X-Hub-Signature-256`). One that does not
verify gets `401` and a log line naming its delivery id, event and reason, never the payload.

## Let Symphony set it up

Symphony runs every step itself; the app's Setup drives it, and `curl` can too:

```sh
curl -s localhost:4040/api/v1/setup | jq .github_updates          # mode, steps, repos
curl -X POST localhost:4040/api/v1/setup/github_updates/turn_on -d '{"relay":"gh_webhook_forward"}'
curl -X POST localhost:4040/api/v1/setup/github_updates/run_step -d '{"step":"secret"}'
curl -X POST localhost:4040/api/v1/setup/github_updates/test
curl -X POST localhost:4040/api/v1/setup/github_updates/turn_off
```

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
repository's test verified, and `degraded` while a relay can't restart or a repository heard
nothing for `silence_alert_minutes` after a read found a change no delivery reported. A
`symphony.yml` brought from another Mac with webhooks on reads `needs_setup` until the setup runs
on this Mac. Turning off stops the relays, deletes only the hooks Symphony created and keeps the
secret.

Symphony restarts a `gh webhook forward` that stops: when its connection to GitHub drops, the
extension retries three times, 5 seconds apart, then exits ("unable to connect to webhooks server,
forwarding stopped"). Symphony starts it again after 1 second, doubling the wait up to 5 minutes
while it keeps failing, and the section counts the restarts and shows the last error. A second
`gh webhook forward` on the same repository fails with `Hook already exists`.

The rest of this page sets webhooks up by hand.

## 1. Pin the dashboard port

The relay needs a fixed address. In `symphony.yml`:

```yaml
dashboard:
  port: 4040
```

## 2. Create the secret

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

## 3. Turn webhooks on

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

Restart Symphony. The dashboard's **GitHub webhooks** card shows "Active through smee".

## 4. Start a relay

### smee.io

1. Open <https://smee.io/new> and copy the channel URL.
2. Run the client (keep it running, for example with `launchd` or in a `tmux` pane):

   ```sh
   npx smee-client --url https://smee.io/<channel> --target http://127.0.0.1:4040/api/v1/github/webhook
   ```

### Cloudflare Tunnel

```sh
brew install cloudflared
cloudflared tunnel login
cloudflared tunnel create symphony
cloudflared tunnel route dns symphony symphony-hooks.example.com
cloudflared tunnel run --url http://127.0.0.1:4040 symphony
```

The payload URL is `https://symphony-hooks.example.com/api/v1/github/webhook`. Add a Cloudflare
Access bypass rule for that one path if the hostname is behind Access.

### `gh webhook forward`

```sh
gh extension install cli/gh-webhook
gh webhook forward --repo <owner>/<repo> \
  --events check_suite,check_run,workflow_run,pull_request,push,release \
  --secret "$GITHUB_WEBHOOK_SECRET" \
  --url http://127.0.0.1:4040/api/v1/github/webhook
```

This creates the hook itself, so skip step 5. The hook lasts only while the command runs.

## 5. Add the webhook on GitHub

In the repository's **Settings → Webhooks → Add webhook**:

- **Payload URL**: the smee channel URL or the tunnel URL above.
- **Content type**: `application/json`.
- **Secret**: the value from step 2.
- **Events**: "Let me select individual events", then **Check suites**, **Check runs**,
  **Workflow runs**, **Pull requests**, **Pushes** and **Releases**.

GitHub sends a `ping` when the hook is saved. Symphony answers it by reading every watched PR at once,
which also catches up on anything missed. `gh webhook forward` creates the hook, and so sends a
`ping`, every time it starts.

## Checking it works

- The dashboard card shows the time of the last delivery and how many CI results came through the
  relay and how many by polling.
- A log line `PR watch found a change no GitHub delivery reported` names the PR and the change a
  read found that no delivery did; the watcher then polls at the poll interval until the next
  delivery arrives.
- GitHub's **Recent Deliveries** tab shows Symphony's answer: `202` when accepted, `401` for a bad
  signature, `404` while `github.webhooks.enabled` is off, `503` while the PR watcher isn't running
  (`pull_requests` polling off).
