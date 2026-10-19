defmodule SymphonyElixir.RepoTeams do
  @moduledoc """
  The Linear teams a repository's route is in, for every path that needs a team: startup
  provisioning of the machine-owned states and labels (`SymphonyElixir.StateProvisioning`), the
  waiting-on-sub-issues state check (`SymphonyElixir.SubIssueWait`), the team self-heal files its
  fix tickets in when the affected issue carries none (`SymphonyElixir.SelfHeal.Fixer`), and the
  Setup checks (`SymphonyElixir.Setup.Checks.Teams` and the label and status checks after it).

  A repo's teams are, in this order:

    1. its `route.team`, else the `issues` team its poll filters by too;
    2. else the teams of the projects its route names (`route.projects`, else the `issues`
       project), from the projects lookup cached with Setup's per-team cache
       (`SymphonyElixir.Setup.TeamCache`), so a project-routed repo costs one Linear request per
       refresh interval;
    3. else the teams of the issues its last poll returned (`observe/2`).

  A repo that resolves nothing has no team: self-heal can't file its fix tickets, and its states and
  labels are never checked. The Setup `teams` check reports it.
  """

  require Logger

  alias SymphonyElixir.{Config, Setup, Tracker}
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Setup.TeamCache

  @typedoc """
  How a repo's teams resolved: `source` is the step that found them (`:none` when none did),
  `teams` the team keys, `project_teams` the teams of its routed projects (whatever the source) and
  `unresolved_projects` the routed projects the lookup found no team for.
  """
  @type resolution :: %{
          source: :route | :projects | :issues | :none,
          teams: [String.t()],
          projects: [String.t()],
          project_teams: [String.t()],
          unresolved_projects: [String.t()]
        }

  @typedoc "Reads the projects a route names, with their teams."
  @type projects_lookup :: ([String.t()] -> {:ok, [Tracker.project()]} | {:error, term()})

  @doc """
  The team keys of `repo` (a `SystemSchema.Repo` or a map with `name`, `team` and `projects`), most
  specific first. A projects lookup that fails is logged and skipped, so the polled issues' teams
  still count. See `resolve/2` for the options.
  """
  @spec routed_teams(map(), keyword()) :: [String.t()]
  def routed_teams(repo, opts \\ []) when is_map(repo) do
    case resolve(repo, opts) do
      {:ok, %{teams: teams}} ->
        teams

      {:error, reason} ->
        Logger.warning("Could not look up the Linear teams of repo=#{repo_key(repo)}'s routed projects: #{inspect(reason)}")
        issue_teams(repo_key(repo))
    end
  end

  @doc """
  How `repo`'s teams resolve, step by step. `{:error, reason}` when its projects had to be looked up
  and Linear could not be read.

  Options: `:tracker` (the `issues` settings, the running config's by default) and `:projects` (a
  `t:projects_lookup/0`, by default the Setup team cache when Setup runs, else the tracker).
  """
  @spec resolve(map(), keyword()) :: {:ok, resolution()} | {:error, term()}
  def resolve(repo, opts \\ []) when is_map(repo) do
    tracker = Keyword.get_lazy(opts, :tracker, &tracker_settings/0)
    projects = routed_projects(repo, tracker)

    case present(Map.get(repo, :team)) || present(tracker && Map.get(tracker, :team)) do
      nil -> resolve_projects(repo, projects, Keyword.get(opts, :projects, &lookup_projects/1))
      team -> {:ok, resolution(:route, [team], projects, [], [])}
    end
  end

  @doc """
  Remembers the teams of the issues a poll of `repo_key` returned, the last step of `resolve/2`. A
  failed or empty poll keeps what an earlier one saw.
  """
  @spec observe(String.t() | nil, {:ok, [term()]} | {:error, term()} | term()) :: :ok
  def observe(repo_key, {:ok, issues}) when is_binary(repo_key) and is_list(issues) do
    teams = issues |> Enum.flat_map(&issue_team/1) |> Enum.uniq()

    # A persistent term is rewritten only when the teams change, which a steady poll never does.
    if teams != [] and teams != issue_teams(repo_key), do: :persistent_term.put(issue_teams_key(repo_key), teams)
    :ok
  end

  def observe(_repo_key, _poll_result), do: :ok

  @doc "The teams of the issues the last poll of `repo_key` returned (`observe/2`)."
  @spec issue_teams(String.t() | nil) :: [String.t()]
  def issue_teams(repo_key) when is_binary(repo_key), do: :persistent_term.get(issue_teams_key(repo_key), [])
  def issue_teams(_repo_key), do: []

  @doc "Forgets what the polls of `repo_key` saw."
  @spec forget(String.t()) :: :ok
  def forget(repo_key) when is_binary(repo_key) do
    :persistent_term.erase(issue_teams_key(repo_key))
    :ok
  end

  defp resolve_projects(repo, [], _lookup), do: {:ok, issues_resolution(repo, [], [], [])}

  defp resolve_projects(repo, projects, lookup) do
    with {:ok, found} <- lookup.(projects) do
      by_ref = Enum.map(projects, &{&1, project_team_keys(found, &1)})
      project_teams = by_ref |> Enum.flat_map(&elem(&1, 1)) |> Enum.uniq()
      unresolved = for {ref, []} <- by_ref, do: ref

      case project_teams do
        [] -> {:ok, issues_resolution(repo, projects, project_teams, unresolved)}
        teams -> {:ok, resolution(:projects, teams, projects, project_teams, unresolved)}
      end
    end
  end

  defp issues_resolution(repo, projects, project_teams, unresolved) do
    case issue_teams(repo_key(repo)) do
      [] -> resolution(:none, [], projects, project_teams, unresolved)
      teams -> resolution(:issues, teams, projects, project_teams, unresolved)
    end
  end

  defp resolution(source, teams, projects, project_teams, unresolved) do
    %{source: source, teams: teams, projects: projects, project_teams: project_teams, unresolved_projects: unresolved}
  end

  # A route names a project by its name, slug id or id, as the poll filter reads it.
  defp project_team_keys(found, ref) do
    found
    |> Enum.filter(&(ref in [Map.get(&1, :id), Map.get(&1, :name), Map.get(&1, :slug_id)]))
    |> Enum.flat_map(&List.wrap(Map.get(&1, :team_keys)))
  end

  # The projects a route polls: its own, else the `issues` project, as `Linear.Client` filters by.
  defp routed_projects(repo, tracker) do
    case repo |> Map.get(:projects) |> List.wrap() |> Enum.flat_map(&List.wrap(present(&1))) |> Enum.uniq() do
      [] -> List.wrap(present(tracker && Map.get(tracker, :project_slug)))
      projects -> projects
    end
  end

  defp lookup_projects(refs) do
    case Setup.team_cache() do
      %TeamCache{} = cache -> TeamCache.projects(cache, refs)
      nil -> Tracker.fetch_projects(refs)
    end
  end

  defp tracker_settings do
    case Config.settings() do
      {:ok, settings} -> settings.tracker
      {:error, _reason} -> nil
    end
  end

  defp issue_team(%Issue{team: %{key: key}}) when is_binary(key) and key != "", do: [key]
  defp issue_team(_issue), do: []

  defp repo_key(repo), do: Map.get(repo, :name)

  defp issue_teams_key(repo_key), do: {__MODULE__, :issue_teams, repo_key}

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present(_value), do: nil
end
