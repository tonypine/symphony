defmodule SymphonyElixir.HumanActions.Action do
  @moduledoc """
  One thing only a human can do, as listed in a project's human-action update.

  `key` identifies the action across polls: the set of keys is what decides whether the update
  changed. `kind` says where it came from:

  - `:request`: an `## Action needed:` comment (`linear_request_human_action`, or written by hand);
  - `:task`: an issue carrying the `human_actions.label` label with no request comment;
  - `:plan_review`: a plan parent waiting in `In Review` for its plan to be approved;
  - `:qa_blocked`: an issue whose latest QA report says Auto Review was `blocked`;
  - `:human_review`: an issue waiting in the Human Review state with no other action;
  - `:verification_blocked`: a `Final verification:` ticket whose Auto Review parent walkthrough
    was `blocked` (a QA host without its macOS permissions), listed on the parent's project;
  - `:ci_secret`: a workflow on a repository's base branch that keeps failing on a missing secret
    (see `SymphonyElixir.HumanActions.CiSecrets`). It belongs to no issue, so its `issue` is nil.

  `human_review` is true when the action's issue sits in the Human Review state
  (`SymphonyElixir.HumanReview`): the update lists those first.
  """

  @enforce_keys [:key, :kind, :title, :issue, :project]
  defstruct @enforce_keys ++ [:why, :unblocks, :est_minutes, :done_when, steps: [], human_review: false]

  @type kind ::
          :request | :task | :plan_review | :qa_blocked | :human_review | :verification_blocked | :ci_secret
  @type t :: %__MODULE__{
          key: String.t(),
          kind: kind(),
          title: String.t(),
          why: String.t() | nil,
          unblocks: String.t() | nil,
          est_minutes: pos_integer() | nil,
          done_when: String.t() | nil,
          steps: [String.t()],
          human_review: boolean(),
          issue:
            %{
              id: String.t(),
              identifier: String.t(),
              title: String.t() | nil,
              url: String.t() | nil,
              state: String.t() | nil
            }
            | nil,
          project: %{id: String.t(), name: String.t() | nil}
        }
end
