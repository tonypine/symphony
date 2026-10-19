defmodule SymphonyElixir.Setup.Checks.Labels do
  @moduledoc """
  The labels Symphony applies or reads (`SymphonyElixir.StateProvisioning.machine_labels/2`), in
  each routed team as `SymphonyElixir.RepoTeams` resolves it, from one labels read per team through
  the team cache. A team label and a workspace label both count.

    * Missing (L1): a label the team can't use. The labels Symphony creates and writes itself
      (`Blocked`, `Needs Decision`, the CI labels) are errors and count only spelled exactly; the
      ones people add for Symphony to read are warnings and count in any case. The fix creates the
      exact name in the team.
    * Near miss (L2, warning): a label that is not one of them but is close to one: it differs
      only by case or spaces, or is a short edit distance away (`SymphonyElixir.Setup.NearMatch`).
      Renaming a label people use isn't safe to automate, so the fix opens Linear.
    * Duplicate (L2, warning): a machine label that is both a team label and a workspace label.

  A team whose labels read returns none at all is one the key can't see (or a fake tracker nobody
  seeded), so nothing is called missing in it.
  """

  @behaviour SymphonyElixir.Setup.Check

  alias SymphonyElixir.{RepoTeams, StateProvisioning}
  alias SymphonyElixir.Setup.{NearMatch, Problem, TeamCache}

  @impl true
  def id, do: "labels"

  @impl true
  def title, do: "Symphony's labels in each Linear team"

  @impl true
  def needs_linear?, do: true

  @impl true
  def run(%{system: nil}), do: []

  def run(%{system: system, team_cache: cache}) do
    with {:ok, teams} <- teams(system.repos, cache) do
      Enum.reduce_while(teams, [], &add_team(&1, &2, system, cache))
    end
  end

  defp add_team({team, repos}, problems, system, cache) do
    case read_team(system, cache, team, repos) do
      {:error, reason} -> {:halt, {:error, reason}}
      team_problems -> {:cont, problems ++ team_problems}
    end
  end

  # A team's problems, from its one labels read.
  defp read_team(system, cache, team, repos) do
    case TeamCache.labels(cache, team) do
      {:ok, []} -> []
      {:ok, labels} -> team_problems(team, repos, wanted(system, repos), labels)
      {:error, reason} -> {:error, reason}
    end
  end

  # Each routed team, in the order the repos name them, with the repos routed to it.
  defp teams(repos, cache) do
    opts = [projects: fn -> RepoTeams.cached_projects(cache) end]

    Enum.reduce_while(repos, {:ok, []}, fn repo, {:ok, teams} ->
      case RepoTeams.resolve(repo, opts) do
        {:ok, %{teams: repo_teams}} -> {:cont, {:ok, Enum.reduce(repo_teams, teams, &add_repo(&2, &1, repo.name))}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp add_repo(teams, team, repo_name) do
    case List.keyfind(teams, team, 0) do
      nil -> teams ++ [{team, [repo_name]}]
      {^team, names} -> List.keyreplace(teams, team, 0, {team, Enum.uniq(names ++ [repo_name])})
    end
  end

  defp wanted(system, repo_names) do
    escalate =
      for repo <- system.repos, repo.name in repo_names, label <- escalate_labels(system, repo), uniq: true, do: label

    StateProvisioning.machine_labels(system.agent.force_label, escalate)
  end

  # A repo's `acceptance_gate` override is its effective block, the global one merged in.
  defp escalate_labels(system, repo) do
    case get_in(repo.acceptance_gate || %{}, ["escalate", "labels"]) do
      labels when is_list(labels) -> labels
      nil -> system.auto_review.acceptance_gate.escalate.labels
    end
  end

  defp team_problems(team, repos, wanted, labels) do
    labels = Enum.filter(labels, &is_binary(&1.name))

    Enum.flat_map(wanted, &missing(team, repos, &1, labels)) ++
      Enum.flat_map(labels, &near_miss(team, repos, &1, wanted)) ++
      Enum.flat_map(wanted, &duplicate(team, repos, &1, labels))
  end

  # L1: none of the label's names is one the team can use.
  defp missing(team, repos, %{names: [name | others]} = wanted, labels) do
    if Enum.any?(labels, &matches?(wanted, &1.name)) do
      []
    else
      [
        Problem.new(
          id: "#{id()}:missing:#{team}:#{name}",
          severity: wanted.severity,
          category: :labels,
          title: ~s(Team #{team} has no "#{name}" label),
          consequence: wanted.shows,
          repos: repos,
          details: [Team: team, Label: name, "Also accepted": join(others)],
          fix: Problem.linear("create_label", team, name)
        )
      ]
    end
  end

  # L2: a label close to a machine label that isn't one.
  defp near_miss(team, repos, label, wanted) do
    with false <- Enum.any?(wanted, &matches?(&1, label.name)),
         name when is_binary(name) <- Enum.find_value(wanted, &Enum.find(&1.names, fn name -> NearMatch.near?(label.name, name) end)) do
      [
        Problem.new(
          id: "#{id()}:near_miss:#{team}:#{label.name}",
          severity: :warning,
          category: :labels,
          title: ~s(Team #{team}'s label "#{label.name}" looks like "#{name}"),
          consequence:
            ~s(Symphony reads only "#{name}", so it ignores "#{label.name}" on every ticket. Rename or remove it in Linear: ) <>
              "a rename keeps it on the tickets that have it.",
          repos: repos,
          details: [Team: team, Label: label.name, "Symphony's label": name, Scope: scope(label)],
          fix: Problem.open(:linear)
        )
      ]
    else
      _match_or_not_near -> []
    end
  end

  # L2: a machine label that is both a team label and a workspace label.
  defp duplicate(team, repos, %{names: names} = wanted, labels) do
    found = Enum.filter(labels, &matches?(wanted, &1.name))

    case {Enum.find(found, &team_label?/1), Enum.find(found, &(not team_label?(&1)))} do
      {%{name: team_name}, %{name: workspace_name}} ->
        [
          Problem.new(
            id: "#{id()}:duplicate:#{team}:#{hd(names)}",
            severity: :warning,
            category: :labels,
            title: ~s("#{team_name}" is both a team #{team} label and a workspace label),
            consequence:
              "Symphony writes the team's label, so a ticket that carries the workspace one looks the same but isn't read the same. " <>
                "Merge them in Linear.",
            repos: repos,
            details: [Team: team, "Team label": team_name, "Workspace label": workspace_name],
            fix: Problem.open(:linear)
          )
        ]

      _one_or_none ->
        []
    end
  end

  defp matches?(%{names: names, exact?: true}, name), do: name in names
  defp matches?(%{names: names, exact?: false}, name), do: normalize(name) in Enum.map(names, &normalize/1)

  defp team_label?(label), do: not is_nil(Map.get(label, :team_key) || Map.get(label, :team_id))

  defp scope(label), do: if(team_label?(label), do: "team label", else: "workspace label")

  defp join([]), do: nil
  defp join(values), do: Enum.join(values, ", ")

  defp normalize(value), do: value |> String.trim() |> String.downcase()
end
