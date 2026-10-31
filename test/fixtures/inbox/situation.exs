# One Inbox situation, both ways (`SymphonyElixir.Inbox.FromRecordTest`):
#
# - `nodes`: the tickets as Linear holds them, the fields the Inbox's detail query reads, with the
#   request comments the pause projector posted for their Questions;
# - `questions`, `holds` and `pauses`: what each ticket's record holds beside what an observation
#   of its node writes (`projected` names each Question's request comment);
# - `snapshot`: the orchestrator's, with one quality-gate clarification.
#
# The situation: two open questions on different tickets (SHOP-1, SHOP-2, whose confirmation
# merges it), one plan under review with two sub-tickets and one open choice (SHOP-3), one stopped
# ticket (SHOP-4), one clarification (SHOP-5), and a question answered both in Linear and on the
# record (SHOP-6), which waits on nobody.

director = %{kind: :person, name: "Director"}
run = %{kind: :run, name: "Implementation run", run_id: "run-1"}
plan_run = %{kind: :run, name: "Plan run", run_id: "run-3"}

option = fn label, effect, recommended, tradeoffs ->
  Map.merge(%{label: label, effect: effect, good: [], cost: [], risk: [], recommended?: recommended, unlocks: []}, tradeoffs)
end

question = fn attrs ->
  Map.merge(
    %{
      asked_by: run,
      step: nil,
      unblocks: nil,
      confirm: nil,
      request: true,
      state: :open,
      answer: nil,
      withdrawn: nil,
      legacy_event: nil,
      reopened_at: nil,
      taken_back: []
    },
    attrs
  )
end

moved = fn from, to, at -> %{"createdAt" => at, "fromState" => %{"name" => from}, "toState" => %{"name" => to}} end

node = fn identifier, attrs ->
  Map.merge(
    %{
      "id" => "id-" <> identifier,
      "identifier" => identifier,
      "title" => "Title of " <> identifier,
      "description" => "What " <> identifier <> " does.",
      "url" => "https://linear.app/acme/issue/" <> identifier,
      "labels" => %{"nodes" => []},
      "attachments" => %{"nodes" => []},
      "children" => %{"nodes" => []},
      "comments" => %{"nodes" => [], "pageInfo" => %{"hasPreviousPage" => false}},
      "history" => %{"nodes" => [], "pageInfo" => %{"hasNextPage" => false}}
    },
    attrs
  )
end

comments = fn nodes -> %{"nodes" => nodes, "pageInfo" => %{"hasPreviousPage" => false}} end
history = fn nodes -> %{"nodes" => nodes, "pageInfo" => %{"hasNextPage" => false}} end

signing_body =
  "## Decision needed: Add the signing secret\n\n**Question:** Should Symphony sign the release builds with a new secret?\n**Why:** Releases fail to sign. The old certificate expired.\n**If unanswered:** Every release stays unsigned.\n**Unblocks:** the Release workflow\n\n**Options:**\n1. **Add it** (recommended): Releases sign again.\n   - Good: Gatekeeper stops warning.\n   - Cost: One setup step.\n2. **Drop signing**: Unsigned builds ship.\n   - Risk: Users see a warning.\n\n**Why recommended:** Signing is a one-time setup.\n\n_Reply with the option you pick, or answer it in the Symphony Inbox: the ticket stays in In Progress until the decision is recorded. Symphony lists this in the project update until then._\n\n<!-- symphony:question q-signing -->"

merge_body =
  "## Decision needed: Merge SHOP-2 (Retry the importer)\n\n**Question:** QA passed SHOP-2. Should it merge?\n**Why:** Manual review is on. QA passed the importer retry.\n**If unanswered:** SHOP-2 waits in QA.\n\n**Options:**\n1. **Merge it** (recommended): SHOP-2 moves to Merging.\n   - Good: The fix ships today.\n2. **Send it back**: SHOP-2 goes to Rework.\n   - Cost: Another review round.\n\n**Why recommended:** Review and QA both passed.\n\n_Reply with the option you pick, or answer it in the Symphony Inbox: the ticket stays in QA until the decision is recorded. Symphony lists this in the project update until then._\n\n<!-- symphony:question q-merge -->"

plan_body =
  "## Decision needed: Pick the export format\n\n**Question:** Should the export write CSV or JSON?\n**Why:** The plan's second sub-ticket writes the export. Both formats work.\n**If unanswered:** SHOP-3's plan waits for approval.\n\n**Options:**\n1. **CSV** (recommended): The export writes CSV.\n   - Good: Opens in a spreadsheet.\n2. **JSON**: The export writes JSON.\n   - Cost: Needs a viewer.\n\n**Why recommended:** The operators read exports in a spreadsheet.\n\n_Reply with the option you pick, or answer it in the Symphony Inbox: the ticket stays in Plan Review until the decision is recorded. Symphony lists this in the project update until then._\n\n<!-- symphony:question q-plan -->"

answered_body =
  "## Decision needed: Keep the old endpoint\n\n**Question:** Should the old endpoint stay for a release?\n**Why:** Two clients still call it.\n**If unanswered:** SHOP-6 stays paused.\n\n**Options:**\n1. **Keep it** (recommended): The endpoint stays one release.\n2. **Remove it**: The endpoint goes now.\n\n**Why recommended:** Clients need a release to move.\n\n_Reply with the option you pick, or answer it in the Symphony Inbox: the ticket stays in In Progress until the decision is recorded. Symphony lists this in the project update until then._\n\n<!-- symphony:question q-answered -->"

brief_body = """
## Review brief

**What to review:** The export plan: two sub-tickets and one choice.

- [SHOP-31](https://linear.app/acme/issue/SHOP-31): the export model
- [SHOP-32](https://linear.app/acme/issue/SHOP-32): the export writer

**Decisions needed:**

1. Pick the export format: https://linear.app/acme/issue/SHOP-3#comment-c-plan

**How to approve / change / reject:**

- Approve: move the parent to Waiting on sub-tickets.
- Change: answer the plan's questions, or ask for changes.
- Reject: move the parent to Rework.
"""

stop_reason = "Stopped by you at 12:00. Unblock runs it again where it stopped; Restart starts it over from main."

%{
  nodes: [
    node.("SHOP-1", %{
      "title" => "Sign the release builds",
      "state" => %{"name" => "In Progress"},
      "comments" => comments.([%{"id" => "c-signing", "body" => signing_body, "createdAt" => "2026-10-20T10:00:00.000Z", "parent" => nil}]),
      "history" => history.([moved.("Todo", "In Progress", "2026-10-20T09:00:00.000Z")])
    }),
    node.("SHOP-2", %{
      "title" => "Retry the importer",
      "state" => %{"name" => "QA"},
      "comments" => comments.([%{"id" => "c-merge", "body" => merge_body, "createdAt" => "2026-10-20T11:00:00.000Z", "parent" => nil}]),
      "history" => history.([moved.("Code Review", "QA", "2026-10-20T08:00:00.000Z")])
    }),
    node.("SHOP-3", %{
      "title" => "Export the orders",
      "state" => %{"name" => "Plan Review"},
      "labels" => %{"nodes" => [%{"name" => "plan"}]},
      "children" => %{
        "nodes" => [
          %{"identifier" => "SHOP-32", "title" => "The export writer", "url" => "https://linear.app/acme/issue/SHOP-32", "createdAt" => "2026-10-20T06:41:00.000Z", "state" => %{"name" => "Backlog"}},
          %{"identifier" => "SHOP-31", "title" => "The export model", "url" => "https://linear.app/acme/issue/SHOP-31", "createdAt" => "2026-10-20T06:40:00.000Z", "state" => %{"name" => "Backlog"}}
        ]
      },
      "comments" =>
        comments.([
          %{"id" => "c-plan", "body" => plan_body, "createdAt" => "2026-10-20T06:50:00.000Z", "parent" => nil},
          %{"id" => "c-brief", "body" => brief_body, "createdAt" => "2026-10-20T06:55:00.000Z", "parent" => nil}
        ]),
      "history" => history.([moved.("In Progress", "Plan Review", "2026-10-20T07:00:00.000Z")])
    }),
    node.("SHOP-4", %{
      "title" => "Rebuild the search index",
      "state" => %{"name" => "In Progress"},
      "history" => history.([moved.("Todo", "In Progress", "2026-10-20T11:30:00.000Z")])
    }),
    node.("SHOP-6", %{
      "title" => "Retire the old endpoint",
      "state" => %{"name" => "In Progress"},
      "comments" =>
        comments.([
          %{"id" => "c-answered", "body" => answered_body, "createdAt" => "2026-10-20T09:30:00.000Z", "parent" => nil},
          %{"id" => "c-reply", "body" => "Keep it", "createdAt" => "2026-10-20T09:45:00.000Z", "parent" => %{"id" => "c-answered"}}
        ]),
      "history" => history.([moved.("Todo", "In Progress", "2026-10-20T09:00:00.000Z")])
    })
  ],
  questions: %{
    "id-SHOP-1" => [
      question.(%{
        id: "q-signing",
        asked_in: "In Progress",
        asked_at: ~U[2026-10-20 10:00:00.000Z],
        title: "Add the signing secret",
        question: "Should Symphony sign the release builds with a new secret?",
        why: "Releases fail to sign. The old certificate expired.",
        if_unanswered: "Every release stays unsigned.",
        unblocks: "the Release workflow",
        options: [
          option.("Add it", "Releases sign again.", true, %{good: ["Gatekeeper stops warning."], cost: ["One setup step."]}),
          option.("Drop signing", "Unsigned builds ship.", false, %{risk: ["Users see a warning."]})
        ],
        recommendation_reason: "Signing is a one-time setup."
      })
    ],
    "id-SHOP-2" => [
      question.(%{
        id: "q-merge",
        asked_by: %{kind: :symphony, name: "Symphony", run_id: nil},
        asked_in: "QA",
        asked_at: ~U[2026-10-20 11:00:00.000Z],
        title: "Merge SHOP-2 (Retry the importer)",
        question: "QA passed SHOP-2. Should it merge?",
        why: "Manual review is on. QA passed the importer retry.",
        if_unanswered: "SHOP-2 waits in QA.",
        confirm: "Merging",
        options: [
          option.("Merge it", "SHOP-2 moves to Merging.", true, %{good: ["The fix ships today."]}),
          option.("Send it back", "SHOP-2 goes to Rework.", false, %{cost: ["Another review round."]})
        ],
        recommendation_reason: "Review and QA both passed."
      })
    ],
    "id-SHOP-3" => [
      question.(%{
        id: "q-plan",
        asked_by: plan_run,
        asked_in: "Plan Review",
        asked_at: ~U[2026-10-20 06:50:00.000Z],
        title: "Pick the export format",
        question: "Should the export write CSV or JSON?",
        why: "The plan's second sub-ticket writes the export. Both formats work.",
        if_unanswered: "SHOP-3's plan waits for approval.",
        options: [
          option.("CSV", "The export writes CSV.", true, %{good: ["Opens in a spreadsheet."]}),
          option.("JSON", "The export writes JSON.", false, %{cost: ["Needs a viewer."]})
        ],
        recommendation_reason: "The operators read exports in a spreadsheet."
      })
    ],
    "id-SHOP-6" => [
      question.(%{
        id: "q-answered",
        asked_in: "In Progress",
        asked_at: ~U[2026-10-20 09:30:00.000Z],
        title: "Keep the old endpoint",
        question: "Should the old endpoint stay for a release?",
        why: "Two clients still call it.",
        if_unanswered: "SHOP-6 stays paused.",
        options: [option.("Keep it", "The endpoint stays one release.", true, %{}), option.("Remove it", "The endpoint goes now.", false, %{})],
        recommendation_reason: "Clients need a release to move.",
        state: :answered,
        answer: %{text: "Keep it", option: 1, by: director, at: ~U[2026-10-20 09:45:00.000Z], scope: :ticket}
      })
    ]
  },
  projected: %{
    "id-SHOP-1" => %{"q-signing" => %{comment: "c-signing", reply: nil}},
    "id-SHOP-2" => %{"q-merge" => %{comment: "c-merge", reply: nil}},
    "id-SHOP-3" => %{"q-plan" => %{comment: "c-plan", reply: nil}},
    "id-SHOP-6" => %{"q-answered" => %{comment: "c-answered", reply: "answered"}}
  },
  holds: %{
    "id-SHOP-2" => %{
      kind: :needs_decision,
      reason: "QA passed SHOP-2. Should it merge?",
      clearing_condition: nil,
      waits_on: nil,
      decision: %{title: "Merge SHOP-2 (Retry the importer)", question_id: "q-merge", confirm: "Merging"},
      set_at: ~U[2026-10-20 11:00:00.000Z]
    },
    "id-SHOP-4" => %{
      kind: :blocked,
      reason: stop_reason,
      clearing_condition: "when a person unblocks or restarts it, or moves it on the board",
      waits_on: %{type: "operator_stop", keys: []},
      decision: nil,
      set_at: ~U[2026-10-20 12:00:00.000Z]
    }
  },
  pauses: %{
    "id-SHOP-4" => %{
      reasons: [
        %{
          kind: :person,
          waits_on: %{action: "unblock"},
          text: stop_reason,
          set_by: director,
          set_at: ~U[2026-10-20 12:00:00.000Z],
          releasable: true
        }
      ],
      set_by: director,
      since: ~U[2026-10-20 12:00:00.000Z]
    }
  },
  snapshot: %{
    running: [],
    watching: [],
    awaiting_clarification: [
      %{
        issue_id: "id-SHOP-5",
        identifier: "SHOP-5",
        title: "Make it faster",
        repo_key: nil,
        kind: :clarification,
        state: "Todo",
        url: "https://linear.app/acme/issue/SHOP-5",
        scored_at: ~U[2026-10-20 05:00:00.000Z],
        score: 3,
        pass_threshold: 6,
        rounds_asked: 1,
        max_rounds: 2,
        reason: "No acceptance criteria.",
        questions: ["What should be faster, and by how much?"]
      }
    ]
  }
}
