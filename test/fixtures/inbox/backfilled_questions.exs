# Questions as the run store holds them when the backfill of the holds and decisions (TP-1232)
# wrote them: the shape `SymphonyElixir.Questions` stored before a question carried `unblocks`,
# `request`, `asked_in`, `reopened_at` and `taken_back`. The first is the TP-1074 Question that
# took every state read down on v0.0.1.773 (TP-1323), as the log printed it.
symphony = %{kind: :symphony, name: "Symphony", run_id: nil}

[
  %{
    id: "backfill-e36e1800010dcd90",
    asked_by: symphony,
    step: nil,
    title: "Make the move of TP-1074 to the Job Search Hub project",
    question: "TP-1074 (QA fixtures for the go-back screens and dark mode in QA) sits in the Symphony project. How should it go to the Job Search Hub project?",
    why: "TP-1074 belongs to the Job Search Hub. Symphony cannot move a ticket between projects.",
    if_unanswered: "TP-1074 stays in the Symphony project.",
    options: [
      %{label: "Move it by hand", effect: "You move TP-1074 to the Job Search Hub project.", good: ["One move"], cost: [], risk: [], recommended?: true, unlocks: []},
      %{label: "Leave it", effect: "TP-1074 stays where it is.", good: [], cost: [], risk: ["It is worked in the wrong project"], recommended?: false, unlocks: []}
    ],
    recommendation_reason: "The ticket belongs to the other project.",
    confirm: nil,
    state: :open,
    answer: nil,
    asked_at: ~U[2026-10-12 14:03:00.000000Z],
    withdrawn: nil,
    legacy_event: nil
  },
  # A decision comment whose request text the backfill could not read: no why, no options.
  %{
    id: "backfill-0a1b2c3d4e5f6a7b",
    asked_by: symphony,
    step: nil,
    title: "Ship the go-back screens",
    question: "Should the go-back screens ship?",
    why: "",
    if_unanswered: "",
    options: [],
    recommendation_reason: "",
    confirm: nil,
    state: :open,
    answer: nil,
    asked_at: ~U[2026-10-14 09:00:00.000000Z],
    withdrawn: nil,
    legacy_event: nil
  },
  # A merge confirmation, still open, whose options predate their trade-off lists.
  %{
    id: "backfill-9f8e7d6c5b4a3921",
    asked_by: symphony,
    step: "merge",
    title: "Confirm the merge of TP-1074",
    question: "Code Review and QA passed TP-1074. Should it merge?",
    why: "Manual review is on.",
    if_unanswered: "TP-1074 waits before Merging.",
    options: [%{label: "Merge", effect: "TP-1074 moves to Merging."}, %{label: "Hold", effect: "TP-1074 waits."}],
    recommendation_reason: "Both reviews passed.",
    confirm: "Merging",
    state: :open,
    answer: nil,
    asked_at: ~U[2026-10-15 10:00:00.000000Z],
    withdrawn: nil,
    legacy_event: nil
  },
  # An answered decision the backfill recorded from the Decisions section.
  %{
    id: "backfill-1122334455667788",
    asked_by: symphony,
    step: nil,
    title: "Pick the fixture format",
    question: "Which format should the QA fixtures use?",
    why: "",
    if_unanswered: "",
    options: [],
    recommendation_reason: "",
    confirm: nil,
    state: :answered,
    answer: %{text: "JSON", option: nil, by: %{kind: :person, name: "Director"}, at: ~U[2026-10-16 08:00:00.000000Z], scope: :ticket},
    asked_at: ~U[2026-10-16 07:00:00.000000Z],
    withdrawn: nil,
    legacy_event: "decision.recorded:c-1"
  }
]
