defmodule SymphonyElixir.Setup.Checks.Teams do
  @moduledoc """
  Each repo's Linear team (T1, T2), as `SymphonyElixir.RepoTeams` resolves it for provisioning,
  the state checks and self-heal.

    * A repo with no team at all is an error: QA self-heal can't file its fix tickets, and its
      states and labels are never checked.
    * A repo without `route.team` whose team is only found through Linear (its projects' team, or
      the team of the issues it polls) is a warning. When that is exactly one team, the fix sets
      `route.team` to it. When it is several, self-heal files in the first of them and the operator
      picks one in `symphony.yml`.

  A repo with `route.team` (or the `issues` team) set is never a problem here.
  """

  @behaviour SymphonyElixir.Setup.Check

  alias SymphonyElixir.RepoTeams
  alias SymphonyElixir.Setup.Problem

  @impl true
  def id, do: "teams"

  @impl true
  def title, do: "Each repo's Linear team"

  @impl true
  def needs_linear?, do: true

  @impl true
  def run(%{system: nil}), do: []

  def run(%{system: system, team_cache: cache}) do
    opts = [projects: fn -> RepoTeams.cached_projects(cache) end]

    Enum.reduce_while(system.repos, [], fn repo, problems ->
      case RepoTeams.resolve(repo, opts) do
        {:ok, resolution} -> {:cont, problems ++ problems(repo, resolution)}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp problems(_repo, %{source: :route}), do: []

  defp problems(repo, %{source: :none} = resolution) do
    [
      Problem.new(
        id: "#{id()}:#{repo.name}",
        severity: :error,
        category: :teams,
        title: "#{repo.name} has no Linear team",
        consequence: "QA self-heal can't file fix tickets, and its states and labels are never checked.",
        repos: [repo.name],
        details: details(resolution),
        fix: Problem.open(:symphony_yml)
      )
    ]
  end

  defp problems(repo, %{teams: [team]} = resolution) do
    [
      Problem.new(
        id: "#{id()}:#{repo.name}",
        severity: :warning,
        category: :teams,
        title: "#{repo.name} doesn't name its Linear team",
        consequence:
          "Symphony finds #{team} #{found_through(resolution)}. If that changes, self-heal can't file fix tickets for #{repo.name} " <>
            "and its states and labels stop being checked. Setting the team keeps it fixed.",
        repos: [repo.name],
        details: details(resolution),
        fix: Problem.config_edit(team_path(repo), :set, team)
      )
    ]
  end

  defp problems(repo, %{teams: [first | _rest] = teams} = resolution) do
    [
      Problem.new(
        id: "#{id()}:#{repo.name}",
        severity: :warning,
        category: :teams,
        title: "#{repo.name} is in several Linear teams",
        consequence:
          "Symphony finds #{Enum.join(teams, ", ")} #{found_through(resolution)}. Self-heal files fix tickets for #{repo.name} in #{first}, " <>
            "the first of them. Set the team to the one its tickets belong to.",
        repos: [repo.name],
        details: details(resolution),
        fix: Problem.open(:symphony_yml)
      )
    ]
  end

  defp found_through(%{source: :projects}), do: "through its projects"
  defp found_through(%{source: :issues}), do: "on the tickets it polls"

  defp details(resolution) do
    [
      Projects: join(resolution.projects),
      "Projects with no team": join(resolution.unresolved_projects),
      Teams: join(resolution.teams)
    ]
  end

  defp join([]), do: nil
  defp join(values), do: Enum.join(values, ", ")

  defp team_path(repo), do: "repositories[#{repo.name}].route.team"
end
