# Linear webhooks

Linear can push every ticket change to Symphony through one workspace webhook, the way GitHub
already pushes pull request changes ([github-webhooks.md](github-webhooks.md)). The settings live
under `linear.webhooks` in `symphony.yml` ([configuration.md](configuration.md#linear)):

```yaml
linear:
  webhooks:
    enabled: false
    secret: $SYMPHONY_LINEAR_WEBHOOK_SECRET
```

Symphony receives the deliveries at `POST /api/v1/linear/webhook`, writes what an `Issue` delivery
says into the ticket's record and counts each one (see [What arrived](#what-arrived)). Nothing
dispatches from the record yet: Symphony still acts on what it polls, as before, and measures how
often the webhook brought a change before the poll did.

## How a delivery is verified

Symphony accepts a delivery only when both hold:

- **It is Linear's.** The `Linear-Signature` header is the hex HMAC-SHA256 of the raw request body,
  keyed with the webhook's signing secret. Symphony computes it over the bytes it received, before
  decoding them, and compares the two in constant time.
- **It is fresh.** The body's `webhookTimestamp`, the milliseconds since the epoch at which Linear
  sent it, is within sixty seconds of Symphony's clock, so a captured delivery can't be replayed
  later.

A refused delivery names why: `missing_secret` (no `secret` set, or its variable unset), then
`missing_signature` (no `Linear-Signature` header), `bad_signature` (the header doesn't match), and
`stale_timestamp` (older or newer than sixty seconds, or no readable `webhookTimestamp`), checked in
that order. `SymphonyElixir.Linear.Webhook.verify/3` makes the check.

`enabled: true` with no `secret` is refused when `symphony.yml` loads (`symphony check` names
`linear.webhooks.secret`). A `$ENV` reference to an unset variable loads, so a missing variable
never stops Symphony from starting, and every delivery is then refused as `missing_secret`.

## Create the webhook

Symphony listens on `127.0.0.1`, so the deliveries reach it
through the same relay as GitHub's; the steps below use the Tailscale Funnel relay.

1. Add the Linear path to the funnel, which serves it on your relay's public `ts.net` URL:

   ```sh
   tailscale funnel --bg --set-path /api/v1/linear/webhook http://127.0.0.1:4000/api/v1/linear/webhook
   ```

   Use your dashboard port in place of `4000` when `dashboard.port` sets another one.
2. In Linear, open **Settings → API → Webhooks** (a workspace admin can) and create a webhook for the
   workspace. Point its URL at the relay's public URL with the path above, such as
   `https://<your-machine>.<tailnet>.ts.net/api/v1/linear/webhook`, and pick the data changes to
   send (issues at least).
3. Copy the signing secret Linear shows for the webhook into `SYMPHONY_LINEAR_WEBHOOK_SECRET` in the
   environment Symphony runs with. Never write the value into `symphony.yml`.
4. Turn the webhook on in `symphony.yml`:

   ```yaml
   linear:
     webhooks:
       enabled: true
       secret: $SYMPHONY_LINEAR_WEBHOOK_SECRET
   ```

   Run `symphony check`: it prints `Config OK` once the settings load. In the macOS app, Settings →
   Linear webhooks has the same switch and the secret's variable (or the secret, typed in a secure
   field), and Save runs the check first.

## What arrived

`POST /api/v1/linear/webhook` answers `404` while `enabled` is off, `401` for a delivery that fails
the check above (logged with its reason only, never its payload), and `200` for an accepted one:
Linear counts any other status as a failed delivery, retries it after one minute, one hour and
six hours, and may turn the webhook off after repeated failures.
An accepted delivery makes no Linear request. Within the request, and bounded to five seconds,
Symphony observes it into the ticket's record (`SymphonyElixir.TicketObservation.observe_delivery/2`):

- An `Issue` create or update is read as the poll reads a ticket and written into the record of the
  repo its team, project and labels route to, as a poll writes it, with `observed_from: webhook`. Its
  observation is `updated`, `unchanged`, `stale` (older than the record's `updatedAt`: dropped) or
  `unrouted` (no repo takes the ticket: nothing is written).
- An `Issue` remove sets the record's `removed_at` in every repo that has one (`removed`), or finds
  none (`no_record`).
- A `Comment` or any other delivery is only counted, with no observation.

A store refusal, a crash or a timeout is logged and counted as `error`; the delivery is still
answered `200`.

`GET /api/v1/state` shows the counts under `linear_webhooks`:

```json
"linear_webhooks": {
  "enabled": true,
  "secret_configured": true,
  "total": 12,
  "rejected": 1,
  "last_at": "2026-10-29T07:40:02Z",
  "last_type": "Issue",
  "last_action": "update",
  "last_rejected_at": "2026-10-29T07:31:10Z",
  "last_rejected_reason": "bad_signature",
  "counts": [{"type": "Issue", "action": "update", "count": 10}, {"type": "Comment", "action": "create", "count": 2}],
  "rejected_reasons": [{"reason": "bad_signature", "count": 1}],
  "observations": {"updated": 9, "unchanged": 1, "stale": 0, "unrouted": 0, "removed": 0, "no_record": 0, "error": 0},
  "recent": [{"type": "Issue", "action": "update", "identifier": "TP-7", "observation": "updated", "received_at": "2026-10-29T07:40:02Z"}],
  "compare": {"webhook_first": 9, "poll_first": 0, "poll_first_recent": []}
}
```

The macOS app's Setup page reads this block from the state it already polls: its Linear webhooks
line says off, on with no deliveries yet, how many arrived and how long ago the last one came, or,
in the warning colour, how many were refused and why the last one was. Against a Symphony without
the block it says the feature is not available.

`recent` holds the last ten accepted deliveries, newest first, each with its `observation` (null
when it wasn't observed); a delivery without a `type` or an `action` counts as `unknown`.
`observations` counts each observation.

`compare` measures the webhook against Symphony's other reads of Linear (the poll, the by-id reads
and the PR and CI watcher's read). A read that finds nothing to change in a record whose last change
came from a webhook counts once under `webhook_first`. A read that changes a field the webhook
carries (the state, identifier, title, labels, priority, assignee or URL) of an existing record, while
`enabled` is on, counts under `poll_first`; `poll_first_recent` keeps the last ten, newest first, with
the ticket, the fields, the read and when:

```json
"compare": {
  "webhook_first": 41,
  "poll_first": 1,
  "poll_first_recent": [{"identifier": "TP-7", "fields": ["priority"], "source": "poll", "at": "2026-10-29T07:42:10Z"}]
}
``` The counts live in memory and start again from zero when Symphony
restarts.
