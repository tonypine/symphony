```text
╭─ SYMPHONY STATUS
│ Dispatch: active
│ Agents: 2/10
│ Throughput: 1,842 tps
│ Runtime: 72m 1s
│ Tokens: new 250,000 | cached 0 | created 0 | out 18,500
│ Rate Limits: gpt-5 | primary 12,345/20,000 reset 30s | secondary 45/60 reset 12s | credits 9876.50
│ Repos: default
│ Next refresh: n/a
├─ Running
│
│   ID       STAGE          PID      AGE / TURN   TOKENS     SESSION        EVENT
│   ───────────────────────────────────────────────────────────────────────────────────────────────────────────────
│ ● MT-101   running        4242     13m 5s / 11     120,450 thre...567890  turn completed (completed)
│     implementation · claude-opus-5-5 · high
│     reviewer: pre_push_review · claude-sonnet-5-5 · default
│ ● MT-102   running        5252     6m 52s / 4       89,200 thre...567890  mix test --cover
│
├─ Watching
│
│   ID       STATE          LAST RUN     LINEAR URL
│   ───────────────────────────────────────────────────────────────────────────────────────────────────────────
│  No watched issues
│
├─ Backoff queue
│
│  No queued retries
├─ Awaiting clarification
│
│  No issues awaiting clarification
├─ Skipped (quality gate)
│
│  No issues skipped this session
│
├─ Recent runs
│
│  ◦ MT-099   qa_pass              18,200 qa · claude-haiku-4-5 · low
│  ◦ MT-098   success               4,100 landing · default · low (reviewer: pre_push_review · claude-sonnet-5-5 · medium)
│  ◦ issue... unknown                   0 profile n/a
╰─
```
