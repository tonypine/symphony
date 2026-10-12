defmodule SymphonyElixir.SelfHeal.Fixer do
  @moduledoc """
  Files and updates the fix tickets the self-heal lane opens, through the machine-side Linear
  adapter (`SymphonyElixir.Linear.Adapter`).

  A fix ticket is created in **Todo** — not Backlog: it is work the machine is already waiting on —
  at high priority, in the team and project that own the broken component: the repo the scope rule
  names (`SymphonyElixir.SelfHeal.scope/3`), read from the configured repositories. The affected
  ticket is linked to it as blocked-by, and a recurring failure attaches its evidence as a comment
  on the fix ticket it already has.

  `SymphonyElixir.SelfHeal` takes this module through `opts[:fixer]`, so tests use a fake and no
  Linear call is made.
  """

  require Logger

  alias SymphonyElixir.{Config, Linear}
  alias SymphonyElixir.Linear.Issue

  # Linear's priority scale: 1 urgent, 2 high.
  @priority 2
  @todo_state "Todo"

  @doc "Files the fix ticket `attrs` (a `scope`, a `component`, a `title` and a `description`)."
  @spec create(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def create(%{scope: scope} = attrs, opts) do
    with {:ok, team, project} <- target(scope, opts) do
      Linear.Adapter.create_issue(%{
        title: attrs.title,
        description: attrs.description,
        priority: Keyword.get(opts, :priority, @priority),
        team: team,
        project: project,
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

  # The team and project the scope repo routes its work to. A repo with no team configured cannot
  # own a fix ticket, so the lane reports it rather than filing somewhere arbitrary.
  defp target(scope, opts) do
    case repo(scope, opts) do
      {:ok, %{team: team, projects: projects}} when is_binary(team) and team != "" ->
        {:ok, team, List.first(projects || [])}

      {:ok, _repo} ->
        {:error, {:self_heal_team_unknown, scope}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp repo(scope, opts) do
    case Keyword.get(opts, :repo, &Config.repo/1).(scope) do
      {:ok, repo} -> {:ok, repo}
      {:error, reason} -> {:error, reason}
    end
  end

  defp tracker(opts), do: Keyword.get(opts, :tracker, SymphonyElixir.Tracker)
end
