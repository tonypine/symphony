defmodule SymphonyElixir.Tracker do
  @moduledoc """
  Adapter boundary for issue tracker reads and writes.
  """

  alias SymphonyElixir.{Config, Linear.Issue}

  @typedoc "A state change in an issue's history: when it happened and the states it moved between."
  @type state_change :: %{at: DateTime.t(), from: String.t() | nil, to: String.t()}

  @typedoc """
  What Symphony reads to act on a `breakdown` parent's review: the parent's state changes, and each
  sub-issue with its creation time and the time of its latest state change (nil when it never moved).
  """
  @type breakdown_history :: %{
          state_changes: [state_change()],
          sub_issues: [
            %{
              id: String.t() | nil,
              identifier: String.t() | nil,
              state: String.t() | nil,
              created_at: DateTime.t() | nil,
              state_changed_at: DateTime.t() | nil
            }
          ]
        }

  @callback fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  @callback fetch_candidate_issues_for_repo(term()) :: {:ok, [term()]} | {:error, term()}
  @callback fetch_issue_by_identifier(String.t()) :: {:ok, Issue.t()} | {:error, term()}
  @callback fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  @callback fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  @callback enrich_issue(Issue.t()) :: {:ok, Issue.t()} | {:error, term()}
  @callback create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  @callback update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  @callback fetch_breakdown_history(String.t()) :: {:ok, breakdown_history()} | {:error, term()}
  @callback workflow_state_exists?(String.t(), [String.t()]) :: {:ok, boolean()} | {:error, term()}

  @spec fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues do
    adapter().fetch_candidate_issues()
  end

  @spec fetch_candidate_issues_for_repo(term()) :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues_for_repo(repo) do
    adapter().fetch_candidate_issues_for_repo(repo)
  end

  @spec fetch_issue_by_identifier(String.t()) :: {:ok, Issue.t()} | {:error, term()}
  def fetch_issue_by_identifier(identifier) when is_binary(identifier) do
    adapter().fetch_issue_by_identifier(identifier)
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states) do
    adapter().fetch_issues_by_states(states)
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) do
    adapter().fetch_issue_states_by_ids(issue_ids)
  end

  @spec enrich_issue(Issue.t()) :: {:ok, Issue.t()} | {:error, term()}
  def enrich_issue(issue) do
    adapter().enrich_issue(issue)
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) do
    adapter().create_comment(issue_id, body)
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name) do
    adapter().update_issue_state(issue_id, state_name)
  end

  @spec fetch_breakdown_history(String.t()) :: {:ok, breakdown_history()} | {:error, term()}
  def fetch_breakdown_history(issue_id) when is_binary(issue_id) do
    adapter().fetch_breakdown_history(issue_id)
  end

  @doc """
  Whether a workflow state with this name exists in every given team (team keys or
  ids). With no teams, any team having it counts.
  """
  @spec workflow_state_exists?(String.t(), [String.t()]) :: {:ok, boolean()} | {:error, term()}
  def workflow_state_exists?(state_name, teams) when is_binary(state_name) and is_list(teams) do
    adapter().workflow_state_exists?(state_name, teams)
  end

  @spec adapter() :: module()
  def adapter do
    case Config.settings!().tracker.kind do
      "memory" -> SymphonyElixir.Tracker.Memory
      _ -> SymphonyElixir.Linear.Adapter
    end
  end
end
