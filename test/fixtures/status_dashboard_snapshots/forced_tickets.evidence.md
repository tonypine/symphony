```text
╭─ SYMPHONY STATUS
│ Dispatch: active
│ Agents: 2/10 · forced 4/1
│ Throughput: 3 tps
│ Runtime: 10m 0s
│ Tokens: new 1,000 | cached 0 | created 0 | out 200
│ Rate Limits: unavailable
│ Repos: default
│ Next refresh: n/a
├─ Forced
│
│   ID       PHASE                WAITING ON               FORCED FOR
│ ⚡MT-F1    implementation       running                  2h 3m
│ ⚡MT-F2    implementation       blocker MT-9, MT-10      5m
│ ⚡MT-F3    waiting for a human  human                    3d 3h stale
│ ⚡MT-EPIC  CI fix               slot                     42s → MT-P1
│
├─ Running
│
│   ID       STAGE          PID      AGE / TURN   TOKENS     SESSION        EVENT
│   ───────────────────────────────────────────────────────────────────────────────────────────────────────────────
│ ● MT-2     In Progress    4242     0m 0s / 1             0 thre...567890  agent message streaming: reading the...
│ ⚡MT-F1    In Progress    4242     0m 0s / 1             0 thre...567890  agent message streaming: writing the...
│
├─ Watching
│
│   ID       STATE          LAST RUN     LINEAR URL
│   ───────────────────────────────────────────────────────────────────────────────────────────────────────────
│  No watched issues
│
├─ Backoff queue
│
│  ↻ MT-F4 ⚡ attempt=2 in 4.000s error=worker crashed
│
├─ Awaiting clarification
│
│  No issues awaiting clarification
├─ Skipped (quality gate)
│
│  No issues skipped this session
│
├─ Recent runs
│
│  No runs yet
╰─
```
