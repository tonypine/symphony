defmodule SymphonyElixir.Linear.Issue do
  @moduledoc """
  Normalized Linear issue representation used by the orchestrator.
  """

  # A human puts this label on a parent ticket to have it groomed into sub-tickets; it stays on while
  # the sub-tickets are worked.
  @breakdown_label "breakdown"

  defstruct [
    :id,
    :identifier,
    :title,
    :description,
    :priority,
    :state,
    :team,
    :project,
    :branch_name,
    :url,
    :pull_request_url,
    :assignee_id,
    :repo_key,
    :run_kind,
    :intent,
    :pr_context,
    :workspace_branch,
    :workspace_base_ref,
    pr_urls: [],
    blocked_by: [],
    sub_issues: [],
    comments: [],
    linked_issues: [],
    conflict_repo_keys: [],
    labels: [],
    assigned_to_worker: true,
    created_at: nil,
    updated_at: nil
  ]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          identifier: String.t() | nil,
          title: String.t() | nil,
          description: String.t() | nil,
          priority: integer() | nil,
          state: String.t() | nil,
          team: %{key: String.t() | nil, name: String.t() | nil} | nil,
          project: %{id: String.t() | nil, name: String.t() | nil} | nil,
          branch_name: String.t() | nil,
          url: String.t() | nil,
          pull_request_url: String.t() | nil,
          assignee_id: String.t() | nil,
          repo_key: String.t() | nil,
          run_kind: atom() | String.t() | nil,
          intent: String.t() | nil,
          pr_context: map() | nil,
          workspace_branch: String.t() | nil,
          workspace_base_ref: String.t() | nil,
          pr_urls: [String.t()],
          sub_issues: [%{id: String.t() | nil, identifier: String.t() | nil, state: String.t() | nil}],
          comments: [%{author: String.t(), body: String.t(), created_at: DateTime.t() | nil}],
          linked_issues: [
            %{relation: String.t(), identifier: String.t(), title: String.t() | nil, state: String.t() | nil}
          ],
          conflict_repo_keys: [String.t()],
          labels: [String.t()],
          assigned_to_worker: boolean(),
          created_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @spec label_names(t()) :: [String.t()]
  def label_names(%__MODULE__{labels: labels}) do
    labels
  end

  @doc """
  True when the issue is a `breakdown` parent with at least one sub-issue outside `terminal_states`;
  such a parent waits in its active state instead of being dispatched. A sub-issue without a known
  state counts as open.
  """
  @spec waiting_on_sub_issues?(t(), Enumerable.t(String.t())) :: boolean()
  def waiting_on_sub_issues?(%__MODULE__{labels: labels, sub_issues: sub_issues}, terminal_states)
      when is_list(labels) and is_list(sub_issues) do
    terminal_states = MapSet.new(terminal_states, &normalize_state/1)

    Enum.any?(labels, &(normalize_state(&1) == @breakdown_label)) and
      Enum.any?(sub_issues, fn
        %{state: state} when is_binary(state) -> !MapSet.member?(terminal_states, normalize_state(state))
        _sub_issue -> true
      end)
  end

  def waiting_on_sub_issues?(_issue, _terminal_states), do: false

  defp normalize_state(state), do: state |> String.trim() |> String.downcase()
end
