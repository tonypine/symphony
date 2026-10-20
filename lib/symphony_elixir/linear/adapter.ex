defmodule SymphonyElixir.Linear.Adapter do
  @moduledoc """
  Linear-backed tracker adapter.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.Linear.{Client, Issue}
  alias SymphonyElixir.{PlanComments, Tracker}

  @create_comment_mutation """
  mutation SymphonyCreateComment($issueId: String!, $body: String!) {
    commentCreate(input: {issueId: $issueId, body: $body}) {
      success
    }
  }
  """

  @create_reply_mutation """
  mutation SymphonyCreateReply($issueId: String!, $parentId: String!, $body: String!) {
    commentCreate(input: {issueId: $issueId, parentId: $parentId, body: $body}) {
      success
    }
  }
  """

  @issue_description_query """
  query SymphonyIssueDescription($issueId: String!) {
    issue(id: $issueId) {
      description
    }
  }
  """

  @update_description_mutation """
  mutation SymphonyUpdateIssueDescription($issueId: String!, $description: String!) {
    issueUpdate(id: $issueId, input: {description: $description}) {
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

  # The team's states and projects, for a create that has a team key rather than an issue to read
  # them from (the self-heal lane's fix tickets).
  @team_scope_query """
  query SymphonyCreateIssueScope($teamId: String!) {
    team(id: $teamId) {
      id
      states(first: 250) {
        nodes {
          id
          name
        }
      }
      projects(first: 250) {
        nodes {
          id
          name
          slugId
        }
      }
    }
  }
  """

  @create_issue_mutation """
  mutation SymphonyCreateIssue($input: IssueCreateInput!) {
    issueCreate(input: $input) {
      success
      issue {
        id
        identifier
        url
      }
    }
  }
  """

  @create_issue_relation_mutation """
  mutation SymphonyCreateIssueRelation($input: IssueRelationCreateInput!) {
    issueRelationCreate(input: $input) {
      success
    }
  }
  """

  # The blocked issue's blocked-by links are its inverse `blocks` relations.
  @blocker_relations_query """
  query SymphonyBlockerRelations($id: String!) {
    issue(id: $id) {
      inverseRelations(first: 100) {
        nodes { id type issue { id identifier } }
      }
    }
  }
  """

  @delete_issue_relation_mutation """
  mutation SymphonyDeleteIssueRelation($id: String!) {
    issueRelationDelete(id: $id) {
      success
    }
  }
  """

  @issue_id_query """
  query SymphonyIssueId($id: String!) {
    issue(id: $id) {
      id
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

  # Provisioning reads every state and label once at startup, then creates only what is missing.
  @teams_query """
  query SymphonyTeams {
    teams(first: 250) {
      nodes {
        id
        key
      }
    }
  }
  """

  @all_workflow_states_query """
  query SymphonyAllWorkflowStates {
    workflowStates(first: 250) {
      nodes {
        id
        name
        team {
          id
          key
        }
      }
    }
  }
  """

  @all_labels_query """
  query SymphonyAllLabels {
    issueLabels(first: 250) {
      nodes {
        id
        name
        team {
          id
          key
        }
      }
    }
  }
  """

  # Setup reads one team's states and labels at a time (`SymphonyElixir.Setup.TeamCache`).
  @team_workflow_states_query """
  query SymphonyTeamWorkflowStates($team: String!) {
    workflowStates(filter: {team: {key: {eqIgnoreCase: $team}}}, first: 250) {
      nodes {
        id
        name
        type
        position
        team {
          id
          key
        }
      }
    }
  }
  """

  @team_labels_query """
  query SymphonyTeamLabels($team: String!) {
    issueLabels(filter: {or: [{team: {key: {eqIgnoreCase: $team}}}, {team: {null: true}}]}, first: 250) {
      nodes {
        id
        name
        team {
          id
          key
        }
      }
    }
  }
  """

  # The Setup routing check reads every project and team once per run, to tell a route value Linear
  # doesn't have from a near miss of one it does. A project's teams give a project-routed repo its
  # team (`SymphonyElixir.RepoTeams`); past a few, all that matters is that there are several.
  @projects_and_teams_query """
  query SymphonyProjectsAndTeams {
    projects(first: 250) {
      nodes {
        id
        name
        slugId
        teams(first: 10) {
          nodes {
            key
          }
        }
      }
    }
    teams(first: 250) {
      nodes {
        id
        key
        name
      }
    }
  }
  """

  # A new phase state is a started state: it sits beside In Progress on the board. Linear requires
  # the color.
  @create_workflow_state_mutation """
  mutation SymphonyCreateWorkflowState($name: String!, $teamId: String!, $color: String!, $type: String!, $position: Float) {
    workflowStateCreate(input: {name: $name, teamId: $teamId, type: $type, color: $color, position: $position}) {
      success
      workflowState {
        id
        name
        type
        position
        team {
          id
          key
        }
      }
    }
  }
  """

  @create_label_mutation """
  mutation SymphonyCreateLabel($name: String!, $teamId: String) {
    issueLabelCreate(input: {name: $name, teamId: $teamId}) {
      success
      issueLabel {
        id
        name
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

  # The newest comments are the ones that matter: a comment counts only after the parent's latest
  # move into its state.
  @plan_comments_query """
  query SymphonyPlanComments($id: String!) {
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
      comments(last: 50, orderBy: createdAt) {
        nodes {
          id
          body
          createdAt
          parent {
            id
          }
          user {
            id
          }
          botActor {
            id
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

  @spec fetch_issues_by_states_with_failures([String.t()]) ::
          {:ok, [term()], [{String.t(), term()}]} | {:error, term()}
  def fetch_issues_by_states_with_failures(states), do: client_module().fetch_issues_by_states_with_failures(states)

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

  @spec create_reply(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def create_reply(issue_id, parent_comment_id, body) when is_binary(issue_id) and is_binary(parent_comment_id) and is_binary(body) do
    variables = %{issueId: issue_id, parentId: parent_comment_id, body: body}

    with {:ok, response} <- client_module().graphql(@create_reply_mutation, variables),
         true <- get_in(response, ["data", "commentCreate", "success"]) == true do
      :ok
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :comment_create_failed}
    end
  end

  @spec fetch_issue_description(String.t()) :: {:ok, String.t() | nil} | {:error, term()}
  def fetch_issue_description(issue_id) when is_binary(issue_id) do
    case client_module().graphql(@issue_description_query, %{issueId: issue_id}) do
      {:ok, %{"data" => %{"issue" => %{} = issue}}} -> {:ok, issue["description"]}
      {:ok, _response} -> {:error, :issue_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec update_issue_description(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_description(issue_id, description) when is_binary(issue_id) and is_binary(description) do
    variables = %{issueId: issue_id, description: description}

    with {:ok, response} <- client_module().graphql(@update_description_mutation, variables),
         true <- get_in(response, ["data", "issueUpdate", "success"]) == true do
      :ok
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :issue_update_failed}
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
  Creates an issue from `attrs` — `title`, `description`, `priority`, `team` (a key or an id),
  `state` (a state name, `Todo` by default), an optional `project` (a name, slug id or id) and an
  optional `assignee_id` (a Linear user id) — and returns its `%{id:, identifier:, url:}`. The
  team's state and project are resolved from the team, so a machine that files work (the self-heal
  lane's fix tickets) does not need an issue to read them from. Only a Linear tracker files issues.
  """
  @spec create_issue(map()) :: {:ok, map()} | {:error, term()}
  def create_issue(attrs) when is_map(attrs) do
    with {:ok, title, description, priority, team, state, project} <- validate_create_issue(attrs),
         {:ok, team_id} <- resolve_team_id(team),
         {:ok, scope} <- team_scope(team_id),
         {:ok, state_id} <- team_state_id(scope, state),
         {:ok, project_id} <- team_project_id(scope, project),
         input =
           team_id
           |> create_issue_input(state_id, project_id, title, description, priority)
           |> maybe_put("assigneeId", attrs |> Map.get(:assignee_id) |> blank_nil()),
         {:ok, response} <- client_module().graphql(@create_issue_mutation, %{input: input}),
         true <- get_in(response, ["data", "issueCreate", "success"]) == true,
         %{"id" => id, "identifier" => identifier} <- get_in(response, ["data", "issueCreate", "issue"]) do
      {:ok, %{id: id, identifier: identifier, url: get_in(response, ["data", "issueCreate", "issue", "url"])}}
    else
      {:error, reason} -> {:error, reason}
      _failed -> {:error, :issue_create_failed}
    end
  end

  def create_issue(_attrs), do: {:error, :invalid_issue_create}

  @doc """
  Records that the issue named `blocker` blocks `blocked_issue_id` (an issue id), so the blocked
  issue cannot move until the blocker goes terminal. Used to tie an affected ticket to the fix
  ticket self-heal filed for it.
  """
  @spec add_blocked_by(String.t(), String.t()) :: :ok | {:error, term()}
  def add_blocked_by(blocker, blocked_issue_id) when is_binary(blocker) and is_binary(blocked_issue_id) do
    with {:ok, blocker_id} <- issue_id(blocker),
         {:ok, response} <-
           client_module().graphql(@create_issue_relation_mutation, %{
             input: %{"issueId" => blocker_id, "relatedIssueId" => blocked_issue_id, "type" => "blocks"}
           }),
         true <- get_in(response, ["data", "issueRelationCreate", "success"]) == true do
      :ok
    else
      {:error, reason} -> {:error, reason}
      _failed -> {:error, :issue_relation_failed}
    end
  end

  def add_blocked_by(_blocker, _blocked_issue_id), do: {:error, :invalid_blocked_by}

  @doc """
  Removes the link `add_blocked_by/2` records: every `blocks` relation from the issue named
  `blocker` (an identifier or an id) to `blocked_issue_id`. A link already gone is `:ok`.
  """
  @spec remove_blocked_by(String.t(), String.t()) :: :ok | {:error, term()}
  def remove_blocked_by(blocker, blocked_issue_id) when is_binary(blocker) and is_binary(blocked_issue_id) do
    with {:ok, response} <- client_module().graphql(@blocker_relations_query, %{id: blocked_issue_id}),
         nodes when is_list(nodes) <- get_in(response, ["data", "issue", "inverseRelations", "nodes"]) do
      nodes
      |> Enum.filter(&(is_map(&1) and &1["type"] == "blocks" and blocker in [get_in(&1, ["issue", "id"]), get_in(&1, ["issue", "identifier"])]))
      |> Enum.reduce_while(:ok, &delete_issue_relation/2)
    else
      {:error, reason} -> {:error, reason}
      _missing -> {:error, {:issue_not_found, blocked_issue_id}}
    end
  end

  def remove_blocked_by(_blocker, _blocked_issue_id), do: {:error, :invalid_blocked_by}

  defp delete_issue_relation(%{"id" => relation_id}, :ok) do
    case client_module().graphql(@delete_issue_relation_mutation, %{id: relation_id}) do
      {:ok, %{"data" => %{"issueRelationDelete" => %{"success" => true}}}} -> {:cont, :ok}
      {:ok, _refused} -> {:halt, {:error, :issue_relation_failed}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp validate_create_issue(attrs) do
    title = attrs |> Map.get(:title) |> blank_nil()
    description = Map.get(attrs, :description, "")
    priority = Map.get(attrs, :priority)
    team = attrs |> Map.get(:team) |> blank_nil()
    state = attrs |> Map.get(:state, "Todo") |> blank_nil()
    project = attrs |> Map.get(:project) |> blank_nil()

    cond do
      is_nil(title) -> {:error, :invalid_issue_title}
      not is_binary(description) -> {:error, :invalid_issue_description}
      not (is_nil(priority) or priority in 0..4) -> {:error, :invalid_issue_priority}
      is_nil(team) -> {:error, :invalid_issue_team}
      is_nil(state) -> {:error, :invalid_issue_state}
      true -> {:ok, title, description, priority, team, state, project}
    end
  end

  defp blank_nil(value) when is_binary(value), do: if(String.trim(value) == "", do: nil, else: String.trim(value))
  defp blank_nil(_value), do: nil

  defp team_scope(team_id) do
    with {:ok, response} <- client_module().graphql(@team_scope_query, %{teamId: team_id}),
         %{} = team <- get_in(response, ["data", "team"]) do
      {:ok, team}
    else
      {:error, reason} -> {:error, reason}
      _missing -> {:error, :team_not_found}
    end
  end

  defp team_state_id(team, state_name) do
    states = team |> get_in(["states", "nodes"]) |> List.wrap()
    wanted = String.downcase(state_name)

    case Enum.find(states, &(is_binary(&1["name"]) and String.downcase(&1["name"]) == wanted)) do
      %{"id" => id} -> {:ok, id}
      _none -> {:error, {:state_not_found, state_name}}
    end
  end

  defp team_project_id(_team, nil), do: {:ok, nil}

  defp team_project_id(team, project_name) do
    projects = team |> get_in(["projects", "nodes"]) |> List.wrap()
    wanted = String.downcase(project_name)

    case Enum.find(projects, &project_named?(&1, wanted)) do
      %{"id" => id} -> {:ok, id}
      _none -> {:error, {:project_not_found, project_name}}
    end
  end

  # A routed project is configured by its slug id (`route.projects`), a fix ticket's by its name.
  defp project_named?(project, wanted) do
    Enum.any?([project["name"], project["slugId"], project["id"]], &(is_binary(&1) and String.downcase(&1) == wanted))
  end

  defp create_issue_input(team_id, state_id, project_id, title, description, priority) do
    %{"teamId" => team_id, "stateId" => state_id, "title" => title, "description" => description}
    |> maybe_put("projectId", project_id)
    |> maybe_put("priority", priority)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp issue_id(identifier) do
    with {:ok, response} <- client_module().graphql(@issue_id_query, %{id: identifier}),
         %{"id" => id} <- get_in(response, ["data", "issue"]) do
      {:ok, id}
    else
      {:error, reason} -> {:error, reason}
      _missing -> {:error, {:issue_not_found, identifier}}
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

  @spec fetch_plan_comments(String.t()) :: {:ok, PlanComments.feedback()} | {:error, term()}
  def fetch_plan_comments(issue_id) when is_binary(issue_id) do
    with {:ok, response} <- client_module().graphql(@plan_comments_query, %{id: issue_id}),
         %{} = issue <- get_in(response, ["data", "issue"]) do
      {:ok,
       %{
         state_changes: issue |> history_nodes() |> Enum.flat_map(&state_change/1),
         comments: issue |> get_in(["comments", "nodes"]) |> List.wrap() |> Enum.map(&plan_comment/1)
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

  @doc "Every workflow state in the workspace, with the team it belongs to."
  @spec workflow_states() :: {:ok, [Tracker.workflow_state()]} | {:error, term()}
  def workflow_states do
    with {:ok, response} <- client_module().graphql(@all_workflow_states_query, %{}),
         nodes when is_list(nodes) <- get_in(response, ["data", "workflowStates", "nodes"]) do
      {:ok, Enum.map(nodes, &workflow_state/1)}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :workflow_states_unavailable}
    end
  end

  @doc """
  Creates the state `state_name` with the hex `color` in the team `team` (a key or an id), and
  returns it. `opts`: `:type` (`started` by default) and `:position` (Linear places it when absent).
  """
  @spec create_workflow_state(String.t(), String.t(), String.t(), keyword()) :: Tracker.created_state()
  def create_workflow_state(state_name, team, color, opts \\ []) when is_binary(state_name) and is_binary(team) and is_binary(color) do
    with {:ok, team_id} <- resolve_team_id(team),
         {:ok, response} <- create_state(state_name, team_id, color, opts),
         true <- get_in(response, ["data", "workflowStateCreate", "success"]) == true,
         %{} = created <- get_in(response, ["data", "workflowStateCreate", "workflowState"]) do
      {:ok, workflow_state(created)}
    else
      false -> {:error, :workflow_state_create_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :workflow_state_create_failed}
    end
  end

  # An absent `position` variable leaves the input field unset, so Linear places the state itself.
  defp create_state(state_name, team_id, color, opts) do
    variables = %{name: state_name, teamId: team_id, color: color, type: Keyword.get(opts, :type) || "started"}
    variables = if is_number(opts[:position]), do: Map.put(variables, :position, opts[:position]), else: variables

    client_module().graphql(@create_workflow_state_mutation, variables)
  end

  @doc "Every label in the workspace, workspace-wide and per team."
  @spec labels() :: {:ok, [Tracker.label()]} | {:error, term()}
  def labels do
    with {:ok, response} <- client_module().graphql(@all_labels_query, %{}),
         nodes when is_list(nodes) <- get_in(response, ["data", "issueLabels", "nodes"]) do
      {:ok, Enum.map(nodes, &label/1)}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :labels_unavailable}
    end
  end

  @doc "The workflow states of the team whose key is `team`."
  @spec team_workflow_states(String.t()) :: {:ok, [Tracker.workflow_state()]} | {:error, term()}
  def team_workflow_states(team) when is_binary(team) do
    with {:ok, response} <- client_module().graphql(@team_workflow_states_query, %{team: team}),
         nodes when is_list(nodes) <- get_in(response, ["data", "workflowStates", "nodes"]) do
      {:ok, Enum.map(nodes, &workflow_state/1)}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :workflow_states_unavailable}
    end
  end

  @doc "The labels the team whose key is `team` can use: its own and the workspace's."
  @spec team_labels(String.t()) :: {:ok, [Tracker.label()]} | {:error, term()}
  def team_labels(team) when is_binary(team) do
    with {:ok, response} <- client_module().graphql(@team_labels_query, %{team: team}),
         nodes when is_list(nodes) <- get_in(response, ["data", "issueLabels", "nodes"]) do
      {:ok, Enum.map(nodes, &label/1)}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :labels_unavailable}
    end
  end

  @doc "Every project (id, name, slug id, its teams' keys) and team (id, key, name) in the workspace, in one request."
  @spec projects_and_teams() :: {:ok, Tracker.projects_and_teams()} | {:error, term()}
  def projects_and_teams do
    with {:ok, response} <- client_module().graphql(@projects_and_teams_query, %{}),
         projects when is_list(projects) <- get_in(response, ["data", "projects", "nodes"]),
         teams when is_list(teams) <- get_in(response, ["data", "teams", "nodes"]) do
      {:ok,
       %{
         projects: Enum.map(projects, &project/1),
         teams: Enum.map(teams, &%{id: &1["id"], key: &1["key"], name: &1["name"]})
       }}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :projects_unavailable}
    end
  end

  defp project(node) do
    team_keys = for team <- List.wrap(get_in(node, ["teams", "nodes"])), is_binary(team["key"]), do: team["key"]
    %{id: node["id"], name: node["name"], slug_id: node["slugId"], team_keys: team_keys}
  end

  @doc "Creates the label `label_name` in the team `team` (a key or an id), and returns it."
  @spec create_label(String.t(), String.t()) :: {:ok, Tracker.label()} | {:error, term()}
  def create_label(label_name, team) when is_binary(label_name) and is_binary(team) do
    with {:ok, team_id} <- resolve_team_id(team),
         {:ok, response} <- client_module().graphql(@create_label_mutation, %{name: label_name, teamId: team_id}),
         true <- get_in(response, ["data", "issueLabelCreate", "success"]) == true,
         %{} = created <- get_in(response, ["data", "issueLabelCreate", "issueLabel"]) do
      {:ok, label(created)}
    else
      false -> {:error, :label_create_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :label_create_failed}
    end
  end

  defp workflow_state(node) do
    %{
      id: node["id"],
      name: node["name"],
      team_id: get_in(node, ["team", "id"]),
      team_key: get_in(node, ["team", "key"]),
      type: node["type"],
      position: node["position"]
    }
  end

  defp label(node) do
    %{id: node["id"], name: node["name"], team_id: get_in(node, ["team", "id"]), team_key: get_in(node, ["team", "key"])}
  end

  # A team key (`TP`) or an id both resolve to the id a create needs.
  defp resolve_team_id(team) do
    with {:ok, response} <- client_module().graphql(@teams_query, %{}),
         nodes when is_list(nodes) <- get_in(response, ["data", "teams", "nodes"]) do
      wanted = String.downcase(team)

      case Enum.find(nodes, &(wanted in [String.downcase(to_string(&1["key"])), String.downcase(to_string(&1["id"]))])) do
        %{"id" => id} -> {:ok, id}
        nil -> {:error, {:team_not_found, team}}
      end
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :teams_unavailable}
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

  # A comment without a user came from an integration, as does one with a bot actor.
  defp plan_comment(comment) do
    %{
      id: comment["id"],
      body: comment["body"],
      created_at: parse_datetime(comment["createdAt"]),
      parent_id: get_in(comment, ["parent", "id"]),
      bot?: is_map(comment["botActor"]) or not is_map(comment["user"])
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
