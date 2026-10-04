defmodule SymphonyElixir.Linear.Adapter do
  @moduledoc """
  Linear-backed tracker adapter.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.Linear.{Client, Issue}
  alias SymphonyElixir.Tracker

  @create_comment_mutation """
  mutation SymphonyCreateComment($issueId: String!, $body: String!) {
    commentCreate(input: {issueId: $issueId, body: $body}) {
      success
    }
  }
  """

  @update_state_mutation """
  mutation SymphonyUpdateIssueState($issueId: String!, $stateId: String!) {
    issueUpdate(id: $issueId, input: {stateId: $stateId}) {
      success
    }
  }
  """

  # The issue's own labels with this name, and every label with this name that the issue's team or
  # the whole workspace defines.
  @issue_label_lookup_query """
  query SymphonyResolveIssueLabel($issueId: String!, $labelName: String!) {
    issue(id: $issueId) {
      team {
        id
      }
      labels(filter: {name: {eqIgnoreCase: $labelName}}) {
        nodes {
          id
        }
      }
    }
    issueLabels(filter: {name: {eqIgnoreCase: $labelName}}, first: 50) {
      nodes {
        id
        team {
          id
        }
      }
    }
  }
  """

  @add_label_mutation """
  mutation SymphonyAddIssueLabel($issueId: String!, $labelId: String!) {
    issueAddLabel(id: $issueId, labelId: $labelId) {
      success
    }
  }
  """

  @remove_label_mutation """
  mutation SymphonyRemoveIssueLabel($issueId: String!, $labelId: String!) {
    issueRemoveLabel(id: $issueId, labelId: $labelId) {
      success
    }
  }
  """

  @state_lookup_query """
  query SymphonyResolveStateId($issueId: String!, $stateName: String!) {
    issue(id: $issueId) {
      team {
        states(filter: {name: {eq: $stateName}}, first: 1) {
          nodes {
            id
          }
        }
      }
    }
  }
  """

  @workflow_states_query """
  query SymphonyWorkflowStatesByName($stateName: String!) {
    workflowStates(filter: {name: {eq: $stateName}}, first: 250) {
      nodes {
        id
        team {
          id
          key
        }
      }
    }
  }
  """

  # Bounded so the nested connection stays cheap; a breakdown parent is read only while it has
  # Backlog sub-issues, and the transition that matters is a recent one.
  @breakdown_history_query """
  query SymphonyBreakdownHistory($id: String!) {
    issue(id: $id) {
      history(first: 50) {
        nodes {
          createdAt
          fromState {
            name
          }
          toState {
            name
          }
        }
      }
      children(first: 50) {
        nodes {
          id
          identifier
          createdAt
          state {
            name
          }
          history(first: 20) {
            nodes {
              createdAt
              toState {
                name
              }
            }
          }
        }
      }
    }
  }
  """

  @spec fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues, do: client_module().fetch_candidate_issues()

  @spec fetch_candidate_issues_for_repo(term()) :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues_for_repo(repo), do: client_module().fetch_candidate_issues_for_repo(repo)

  @spec fetch_issue_by_identifier(String.t()) :: {:ok, Issue.t()} | {:error, term()}
  def fetch_issue_by_identifier(identifier), do: client_module().fetch_issue_by_identifier(identifier)

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states), do: client_module().fetch_issues_by_states(states)

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids), do: client_module().fetch_issue_states_by_ids(issue_ids)

  @spec enrich_issue(Issue.t()) :: {:ok, Issue.t()} | {:error, term()}
  def enrich_issue(issue), do: client_module().fetch_issue_enrichment(issue)

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    with {:ok, response} <- client_module().graphql(@create_comment_mutation, %{issueId: issue_id, body: body}),
         true <- get_in(response, ["data", "commentCreate", "success"]) == true do
      :ok
    else
      false -> {:error, :comment_create_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :comment_create_failed}
    end
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name)
      when is_binary(issue_id) and is_binary(state_name) do
    with {:ok, state_id} <- resolve_state_id(issue_id, state_name),
         {:ok, response} <-
           client_module().graphql(@update_state_mutation, %{issueId: issue_id, stateId: state_id}),
         true <- get_in(response, ["data", "issueUpdate", "success"]) == true do
      :ok
    else
      false -> {:error, :issue_update_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :issue_update_failed}
    end
  end

  @doc """
  Adds the label named `label_name` to the issue: the issue's team label when there is one,
  otherwise the workspace label. Does nothing when the issue already carries it.
  """
  @spec add_issue_label(String.t(), String.t()) :: :ok | {:error, term()}
  def add_issue_label(issue_id, label_name) when is_binary(issue_id) and is_binary(label_name) do
    with {:ok, lookup} <- lookup_issue_label(issue_id, label_name) do
      case lookup do
        %{on_issue: [_ | _]} -> :ok
        %{label_id: nil} -> {:error, {:label_not_found, label_name}}
        %{label_id: label_id} -> mutate_label(@add_label_mutation, "issueAddLabel", issue_id, label_id)
      end
    end
  end

  @doc "Removes every label named `label_name` from the issue. Does nothing when it carries none."
  @spec remove_issue_label(String.t(), String.t()) :: :ok | {:error, term()}
  def remove_issue_label(issue_id, label_name) when is_binary(issue_id) and is_binary(label_name) do
    with {:ok, %{on_issue: label_ids}} <- lookup_issue_label(issue_id, label_name) do
      Enum.reduce_while(label_ids, :ok, fn label_id, :ok ->
        remove_label_id(issue_id, label_id)
      end)
    end
  end

  defp remove_label_id(issue_id, label_id) do
    case mutate_label(@remove_label_mutation, "issueRemoveLabel", issue_id, label_id) do
      :ok -> {:cont, :ok}
      error -> {:halt, error}
    end
  end

  @spec fetch_breakdown_history(String.t()) :: {:ok, Tracker.breakdown_history()} | {:error, term()}
  def fetch_breakdown_history(issue_id) when is_binary(issue_id) do
    with {:ok, response} <- client_module().graphql(@breakdown_history_query, %{id: issue_id}),
         %{} = issue <- get_in(response, ["data", "issue"]) do
      {:ok,
       %{
         state_changes: issue |> history_nodes() |> Enum.flat_map(&state_change/1),
         sub_issues: issue |> get_in(["children", "nodes"]) |> List.wrap() |> Enum.map(&history_sub_issue/1)
       }}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :issue_not_found}
    end
  end

  @spec workflow_state_exists?(String.t(), [String.t()]) :: {:ok, boolean()} | {:error, term()}
  def workflow_state_exists?(state_name, teams) when is_binary(state_name) and is_list(teams) do
    with {:ok, response} <- client_module().graphql(@workflow_states_query, %{stateName: state_name}),
         nodes when is_list(nodes) <- get_in(response, ["data", "workflowStates", "nodes"]) do
      state_teams = Enum.map(nodes, &(&1["team"] || %{}))
      {:ok, if(teams == [], do: state_teams != [], else: Enum.all?(teams, &team_has_state?(&1, state_teams)))}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :workflow_states_unavailable}
    end
  end

  defp team_has_state?(team, state_teams) do
    wanted = String.downcase(team)
    Enum.any?(state_teams, fn state_team -> wanted in [String.downcase(to_string(state_team["key"])), String.downcase(to_string(state_team["id"]))] end)
  end

  defp history_nodes(issue), do: issue |> get_in(["history", "nodes"]) |> List.wrap()

  # History entries for other edits (title, labels, ...) carry no target state.
  defp state_change(%{"toState" => %{"name" => to}} = entry) when is_binary(to) do
    case parse_datetime(entry["createdAt"]) do
      %DateTime{} = at -> [%{at: at, from: get_in(entry, ["fromState", "name"]), to: to}]
      nil -> []
    end
  end

  defp state_change(_entry), do: []

  defp history_sub_issue(child) do
    %{
      id: child["id"],
      identifier: child["identifier"],
      state: get_in(child, ["state", "name"]),
      created_at: parse_datetime(child["createdAt"]),
      state_changed_at: child |> history_nodes() |> Enum.flat_map(&state_change/1) |> Enum.map(& &1.at) |> Enum.max(DateTime, fn -> nil end)
    }
  end

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  defp client_module do
    Application.get_env(:symphony_elixir, :linear_client_module, Client)
  end

  defp lookup_issue_label(issue_id, label_name) do
    variables = %{issueId: issue_id, labelName: label_name}

    with {:ok, response} <- client_module().graphql(@issue_label_lookup_query, variables),
         %{} = issue <- get_in(response, ["data", "issue"]) do
      team_id = get_in(issue, ["team", "id"])
      labels = response |> get_in(["data", "issueLabels", "nodes"]) |> List.wrap()
      team_label = Enum.find(labels, &(is_binary(team_id) and get_in(&1, ["team", "id"]) == team_id))
      workspace_label = Enum.find(labels, &is_nil(&1["team"]))

      {:ok,
       %{
         on_issue: issue |> get_in(["labels", "nodes"]) |> List.wrap() |> Enum.map(& &1["id"]),
         label_id: (team_label || workspace_label || %{})["id"]
       }}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :issue_label_lookup_failed}
    end
  end

  defp mutate_label(mutation, field, issue_id, label_id) do
    case client_module().graphql(mutation, %{issueId: issue_id, labelId: label_id}) do
      {:ok, response} ->
        if get_in(response, ["data", field, "success"]) == true, do: :ok, else: {:error, :issue_label_update_failed}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resolve_state_id(issue_id, state_name) do
    with {:ok, response} <-
           client_module().graphql(@state_lookup_query, %{issueId: issue_id, stateName: state_name}),
         state_id when is_binary(state_id) <-
           get_in(response, ["data", "issue", "team", "states", "nodes", Access.at(0), "id"]) do
      {:ok, state_id}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :state_not_found}
    end
  end
end
