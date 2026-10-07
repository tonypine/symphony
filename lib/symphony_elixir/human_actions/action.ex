defmodule SymphonyElixir.HumanActions.Action do
  @moduledoc """
  One thing only a human can do, as listed in a project's human-action update.

  `key` identifies the action across polls: the set of keys is what decides whether the update
  changed. `kind` says where it came from:

  - `:request`: a `## Decision needed:` comment (`linear_request_human_action`), with its `question`
    and `options`, or an older `## Action needed:` comment written by hand, with its `steps`;
  - `:task`: an issue carrying a deprecated request label (`HumanReview.legacy_request_labels/1`) with no request comment;
  - `:plan_review`: a plan parent waiting in `In Review` for its plan to be approved;
  - `:qa_blocked`: the one step only the operator can take (an app update, a tool to install) to
    clear the cause Auto Review was `blocked` on, for every issue blocked on it, so its `issue` is
    nil and `unblocks` names them;
  - `:human_review`: an issue waiting in the Human Review state with no other action;
  - `:verification_blocked`: a `Final verification:` ticket whose Auto Review parent walkthrough
    was `blocked` (a QA host without its macOS permissions), listed on the parent's project;
  - `:ci_secret`: a workflow on a repository's base branch that keeps failing on a missing secret
    (see `SymphonyElixir.HumanActions.CiSecrets`). It belongs to no issue, so its `issue` is nil.

  `human_review` is true when the action's issue sits in the Human Review state
  (`SymphonyElixir.HumanReview`): the update lists those first.
  """

  @enforce_keys [:key, :kind, :title, :issue, :project]
  defstruct @enforce_keys ++
              [:why, :unblocks, :est_minutes, :done_when, :question, options: [], steps: [], human_review: false]

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
          question: String.t() | nil,
          options: [String.t()],
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
