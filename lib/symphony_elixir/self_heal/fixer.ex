defmodule SymphonyElixir.SelfHeal.Fixer do
  @moduledoc """
  Files and updates the fix tickets the self-heal lane opens, through the machine-side Linear
  adapter (`SymphonyElixir.Linear.Adapter`).

  A fix ticket is created in **Todo** — not Backlog: it is work the machine is already waiting on —
  at the affected ticket's priority when that is more urgent than High (an Urgent ticket's fix is
  Urgent, so `tickets.priorities` dispatches it like the ticket it unblocks), else at High, in the
  affected ticket's Linear team (else the team configured on the repo the
  scope rule names, `SymphonyElixir.SelfHeal.scope/3`) and in the affected ticket's project when
  the fix belongs to its own repo, else the scope repo's first routed project. The affected
  ticket is linked to it as blocked-by, and a recurring failure attaches its evidence as a comment
  on the fix ticket it already has. A reused fix ticket keeps the priority it was filed at.

  The fix ticket is assigned to the user the scope repo's route polls with (its `assignee`, else
  `issues.linear.assignee`, `me` being the API key's user), so Symphony dispatches it: an unassigned
  ticket falls outside an assignee-filtered poll. With no assignee configured, or when it cannot be
  resolved, it takes the affected ticket's assignee.

  `SymphonyElixir.SelfHeal` takes this module through `opts[:fixer]`, so tests use a fake and no
  Linear call is made.
  """

  require Logger

  alias SymphonyElixir.{Config, Linear}
  alias SymphonyElixir.Linear.{Client, Issue}

  # Linear's priority scale: 0 none, 1 urgent, 2 high, 3 medium, 4 low.
  @priority 2
  @todo_state "Todo"

  @doc "Files the fix ticket `attrs` (a `scope`, a `component`, a `title` and a `description`)."
  @spec create(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def create(%{scope: scope} = attrs, opts) do
    with {:ok, repo} <- repo(scope, opts),
         {:ok, team, project} <- target(attrs, repo) do
      Linear.Adapter.create_issue(%{
        title: attrs.title,
        description: attrs.description,
        priority: Keyword.get(opts, :priority, priority(Map.get(attrs, :issue))),
        team: team,
        project: project,
        assignee_id: assignee_id(scope, repo, Map.get(attrs, :issue), opts),
        state: @todo_state
      })
    end
  end

  @doc "Attaches `body` as a comment on the fix ticket named `identifier`."
  @spec attach(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def attach(identifier, body, opts) when is_binary(identifier) and is_binary(body) do
    with {:ok, issue} <- tracker(opts).fetch_issue_by_identifier(identifier) do
      tracker(opts).create_comment(issue.id, body)
    end
  end

  @doc """
  Records that `ticket` blocks `issue`: the affected ticket is blocked by the fix ticket, so it
  cannot move until the fix lands.
  """
  @spec block(Issue.t(), map(), keyword()) :: :ok | {:error, term()}
  def block(%Issue{id: issue_id}, %{identifier: identifier}, _opts) when is_binary(issue_id) and is_binary(identifier) do
    Linear.Adapter.add_blocked_by(identifier, issue_id)
  end

  def block(_issue, _ticket, _opts), do: {:error, :invalid_blocked_by}

  # The team and project the fix ticket goes to. The team is the affected ticket's own Linear team,
  # else the scope repo's configured team: a repo routed only by project sets no team. The project
  # is the affected ticket's when the fix belongs to its own repo, so Symphony picks it up there,
  # else the scope repo's first routed project. With no team at all the lane reports it rather than
  # filing somewhere arbitrary.
  defp target(%{scope: scope} = attrs, repo) do
    issue = Map.get(attrs, :issue)
    own_repo? = scope == Map.get(attrs, :repo_key)

    case present(issue_team(issue)) || present(Map.get(repo, :team)) do
      nil -> {:error, {:self_heal_team_unknown, scope}}
      team -> {:ok, team, (own_repo? && present(issue_project(issue))) || List.first(Map.get(repo, :projects) || [])}
    end
  end

  # The user the scope repo's route polls with, read from its issue filter (`me` already resolved to
  # the API key's user), else the affected ticket's assignee. `nil` leaves the ticket unassigned,
  # which only happens when neither names anyone.
  defp assignee_id(scope, repo, issue, opts) do
    routed =
      case Keyword.get(opts, :scope_filter, &Client.repo_scope_filter/1).(repo) do
        {:ok, filter} ->
          filter |> get_in(["assignee", "id", "in"]) |> List.wrap() |> List.first()

        {:error, reason} ->
          Logger.warning(
            "Self-heal could not resolve the fix ticket's assignee #{issue_context(issue)} repo=#{scope} reason=#{inspect(reason)}; " <>
              "using the affected ticket's assignee"
          )

          nil
      end

    present(routed) || present(issue_assignee_id(issue))
  end

  # High, unless the affected ticket is more urgent: its fix must be dispatched wherever it is.
  defp priority(%Issue{priority: priority}) when priority in 1..@priority, do: priority
  defp priority(_issue), do: @priority

  defp issue_team(%Issue{team: %{key: key}}), do: key
  defp issue_team(_issue), do: nil

  defp issue_project(%Issue{project: %{name: name}}), do: name
  defp issue_project(_issue), do: nil

  defp issue_assignee_id(%Issue{assignee_id: assignee_id}), do: assignee_id
  defp issue_assignee_id(_issue), do: nil

  defp issue_context(%Issue{id: id, identifier: identifier}), do: "issue_id=#{id} issue_identifier=#{identifier}"
  defp issue_context(_issue), do: "issue_id= issue_identifier="

  defp present(value) when is_binary(value) and value != "", do: value
  defp present(_value), do: nil

  defp repo(scope, opts) do
    case Keyword.get(opts, :repo, &Config.repo/1).(scope) do
      {:ok, repo} -> {:ok, repo}
      {:error, reason} -> {:error, reason}
    end
  end

  defp tracker(opts), do: Keyword.get(opts, :tracker, SymphonyElixir.Tracker)
end
