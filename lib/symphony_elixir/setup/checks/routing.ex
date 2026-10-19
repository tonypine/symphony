defmodule SymphonyElixir.Setup.Checks.Routing do
  @moduledoc """
  Each repo's route in Linear, judged on the issues its last poll fetched (`Routing.PollLog`), so it
  asks Linear for no issue of its own:

    * Round-trip (R1, error): a polled issue that `Routing.Resolver.with_repo_key/2` doesn't key
      back to the repo that polled it, as on the TP-899 night, when a slug-routed repo polled its
      tickets and every hold read used no repo. One error per repo, with up to five tickets. The fix
      adds the issues' project id to `route.projects` when re-running the resolver with it shows it
      routes them all back (and keeps every ticket that routes there now).
    * Unknown route values (R2, error): a `route.projects` value no Linear project has as its id,
      slug id or name, or a `route.team` no team has as its key or id. When exactly one project or
      team is a near match (case and spaces, or a short edit distance), the fix sets it.
    * Overlapping routes (R4, error): a polled issue that more than one non-default repo takes,
      whether by its route or by its poll. One error per set of repos.
    * Idle repo (R3, warning): a repo whose polls have fetched no issue for 24 hours.

  It reads the workspace's projects and teams once per run, through the team cache, and only when
  a route names a project or a team. A workspace that lists no team at all is one the key can't
  see (or a fake tracker nobody seeded), so no route value is called unknown against it.
  """

  @behaviour SymphonyElixir.Setup.Check

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Routing.{PollLog, Resolver}
  alias SymphonyElixir.Setup.{Problem, TeamCache}

  @idle_after_s 24 * 60 * 60
  @listed_tickets 5

  @impl true
  def id, do: "routing"

  @impl true
  def title, do: "Each repo's route in Linear"

  @impl true
  def needs_linear?, do: true

  @impl true
  def run(%{system: nil}), do: []

  def run(%{system: system} = context) do
    repos = system.repos

    with {:ok, unknown} <- unknown_values(repos, context.team_cache) do
      polls = for repo <- repos, %{} = entry <- [PollLog.last(repo)], do: {repo, entry}
      overlaps = overlaps(polls, repos)
      overlapping = overlaps |> Enum.flat_map(&elem(&1, 1)) |> MapSet.new(& &1.id)

      Enum.flat_map(polls, &round_trip(&1, repos, overlapping)) ++
        unknown ++ Enum.map(overlaps, &overlap(&1, repos)) ++ Enum.flat_map(polls, &idle(&1, context.now))
    end
  end

  # R1: the polled issues that don't come back keyed to the repo. A default repo catches what its
  # team's scoped repos don't, so an issue it polled that a scoped repo takes is routed as designed.
  defp round_trip({repo, entry}, repos, overlapping) do
    considered =
      for %Issue{} = issue <- entry.issues,
          not MapSet.member?(overlapping, issue.id),
          key <- [keyed(issue, repos)],
          not (repo.default and is_binary(key) and key != repo.name),
          do: {issue, key}

    case for({issue, key} <- considered, key != repo.name, do: issue) do
      [] -> []
      failing -> [round_trip_problem(repo, Enum.map(considered, &elem(&1, 0)), failing, repos)]
    end
  end

  defp round_trip_problem(repo, considered, failing, repos) do
    total = length(considered)
    project = fixing_project(repo, considered, failing, repos)
    count = length(failing)

    Problem.new(
      id: "#{id()}:round_trip:#{repo.name}",
      severity: :error,
      category: :routing,
      title: "#{tickets(count)} #{repo.name} polls don't route back to it",
      consequence:
        "Symphony can't tell which repo #{if count == 1, do: "it belongs", else: "they belong"} to, so it reads and writes holds and decisions " <>
          "with no repo: Inbox decisions fail, Unblock does nothing and Blocked holds never land.",
      repos: [repo.name],
      tickets: listed(failing),
      details: [
        Route: describe_route(repo),
        Resolves: "#{total - count} of #{total} come back to #{repo.name}",
        "Fix adds": project && "project #{project_label(project)} to route.projects"
      ],
      fix: if(project, do: Problem.config_edit(projects_path(repo), :add, project.id), else: Problem.open(:repos))
    )
  end

  # The project the failing issues share most, when adding its id to the route routes every
  # considered issue back to the repo.
  defp fixing_project(repo, considered, failing, repos) do
    with %{id: id} = project when is_binary(id) <- most_common_project(failing),
         false <- id in repo.projects,
         edited = %{repo | projects: repo.projects ++ [id]},
         edited_repos = Enum.map(repos, &if(&1.name == repo.name, do: edited, else: &1)),
         true <- Enum.all?(considered, &(keyed(&1, edited_repos) == repo.name)) do
      project
    else
      _no_fix -> nil
    end
  end

  defp most_common_project(issues) do
    issues
    |> Enum.map(& &1.project)
    |> Enum.filter(&match?(%{id: id} when is_binary(id), &1))
    |> Enum.frequencies_by(& &1.id)
    |> Enum.max_by(&elem(&1, 1), fn -> nil end)
    |> case do
      nil -> nil
      {id, _count} -> issues |> Enum.map(& &1.project) |> Enum.find(&match?(%{id: ^id}, &1))
    end
  end

  defp project_label(%{id: id, name: name}) when is_binary(name), do: "#{name} (#{id})"
  defp project_label(%{id: id}), do: id

  defp keyed(%Issue{} = issue, repos), do: Resolver.with_repo_key(%{issue | repo_key: nil}, repos).repo_key

  # R2: route values Linear has no project or team for.
  defp unknown_values(repos, cache) do
    values =
      for(repo <- repos, value <- repo.projects, do: {:project, repo, value}) ++
        for(%{team: team} = repo <- repos, is_binary(team), do: {:team, repo, team})

    with [_ | _] <- values,
         {:ok, %{teams: [_ | _]} = catalog} <- TeamCache.projects_and_teams(cache) do
      {:ok, for(value <- values, not known?(value, catalog), do: unknown(value, catalog))}
    else
      {:error, reason} -> {:error, reason}
      _no_values_or_no_teams -> {:ok, []}
    end
  end

  defp known?({:project, _repo, value}, catalog), do: Enum.any?(catalog.projects, &(value in [&1.id, &1.slug_id, &1.name]))
  defp known?({:team, _repo, value}, catalog), do: Enum.any?(catalog.teams, &(value in [&1.key, &1.id]))

  defp unknown({:project, repo, value}, catalog) do
    near = near(value, catalog.projects, &[&1.id, &1.slug_id, &1.name])

    unknown_problem(repo, value,
      id: "#{id()}:unknown_project:#{repo.name}:#{value}",
      title: ~s(#{repo.name} routes by project "#{value}", which Linear doesn't have),
      key: projects_path(repo),
      looked_for: ~s(a Linear project whose id, slug id or name is "#{value}"),
      near: near && "#{near.name} (slug id #{near.slug_id}, id #{near.id})",
      fix: near && Problem.config_edit(projects_path(repo), :set, Enum.map(repo.projects, &if(&1 == value, do: near.id, else: &1)))
    )
  end

  # A team is set to its key: fetched issues carry their team's key, not its id.
  defp unknown({:team, repo, value}, catalog) do
    near = near(value, catalog.teams, &[&1.key, &1.id, &1.name])
    path = "repositories[#{repo.name}].route.team"

    unknown_problem(repo, value,
      id: "#{id()}:unknown_team:#{repo.name}",
      title: ~s(#{repo.name} routes by team "#{value}", which Linear doesn't have),
      key: path,
      looked_for: ~s(a Linear team whose key or id is "#{value}"),
      near: near && "#{near.name} (key #{near.key})",
      fix: near && Problem.config_edit(path, :set, near.key)
    )
  end

  defp unknown_problem(repo, value, attrs) do
    Problem.new(
      id: attrs[:id],
      severity: :error,
      category: :routing,
      title: attrs[:title],
      consequence: "Symphony's poll finds no ticket for this value, so tickets meant for #{repo.name} never reach it.",
      repos: [repo.name],
      details: [Repo: repo.name, Key: attrs[:key], Value: value, "Looked for": attrs[:looked_for], "Near match": attrs[:near]],
      fix: attrs[:fix]
    )
  end

  # The one item one of whose names is a near match of `value`, or nil when none or several are.
  defp near(value, items, names) do
    case Enum.filter(items, fn item -> item |> names.() |> Enum.any?(&near?(value, &1)) end) do
      [item] -> item
      _none_or_many -> nil
    end
  end

  defp near?(_value, nil), do: false

  defp near?(value, name) do
    {value, name} = {fold(value), fold(name)}
    value == name or distance(value, name) <= allowed_distance(name)
  end

  defp fold(text), do: text |> String.downcase() |> String.replace(~r/\s+/u, "")

  # A short name is near only when it matches but for case and spaces: two edits turn any two-letter
  # team key into any other.
  defp allowed_distance(name) do
    case String.length(name) do
      length when length >= 6 -> 2
      length when length >= 3 -> 1
      _short -> 0
    end
  end

  # The Levenshtein distance, a row at a time.
  defp distance(left, right) do
    right = String.graphemes(right)

    left
    |> String.graphemes()
    |> Enum.with_index(1)
    |> Enum.reduce(Enum.to_list(0..length(right)), fn {char, row}, previous ->
      previous
      |> Enum.zip(tl(previous))
      |> Enum.zip(right)
      |> Enum.reduce([row], fn {{diagonal, above}, other}, [left_cell | _rest] = cells ->
        [Enum.min([left_cell + 1, above + 1, diagonal + if(char == other, do: 0, else: 1)]) | cells]
      end)
      |> Enum.reverse()
    end)
    |> List.last()
  end

  # R4: each polled issue more than one non-default repo takes, grouped by those repos. A repo takes
  # an issue its route matches, or that its own poll fetched.
  defp overlaps(polls, repos) do
    scoped = Enum.reject(repos, & &1.default)
    scoped_names = MapSet.new(scoped, & &1.name)

    polls
    |> Enum.flat_map(fn {repo, entry} -> for %Issue{id: id} = issue <- entry.issues, is_binary(id), do: {issue, repo.name} end)
    |> Enum.group_by(fn {issue, _repo} -> issue.id end)
    |> Enum.flat_map(fn {_id, [{issue, _repo} | _rest] = polled} ->
      by_route = for repo <- scoped, Resolver.matches?(issue, repo), do: repo.name
      by_poll = for {_issue, name} <- polled, MapSet.member?(scoped_names, name), do: name

      case Enum.sort(Enum.uniq(by_route ++ by_poll)) do
        [_first, _second | _rest] = names -> [{names, issue}]
        _one_or_none -> []
      end
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.sort()
  end

  defp overlap({names, issues}, repos) do
    issues = Enum.sort_by(issues, &(&1.identifier || ""))
    routes = for name <- names, %{} = repo <- [Enum.find(repos, &(&1.name == name))], do: {"#{name} route", describe_route(repo)}

    Problem.new(
      id: "#{id()}:overlap:#{Enum.join(names, "+")}",
      severity: :error,
      category: :routing,
      title: "#{join(names)} #{if length(names) == 2, do: "both", else: "all"} take the same #{if length(issues) == 1, do: "ticket", else: "tickets"}",
      consequence:
        "Symphony can't tell which repo should run #{if length(issues) == 1, do: "it", else: "them"}, so it runs none of them. " <>
          "Only you know which repo owns the project: narrow the other routes.",
      repos: names,
      tickets: listed(issues),
      details: routes ++ [Tickets: tickets(length(issues))],
      fix: Problem.open(:repos)
    )
  end

  # R3: no issue in any poll for a day.
  defp idle({repo, %{idle_since: %DateTime{} = since}}, now) do
    if DateTime.diff(now, since) >= @idle_after_s do
      [
        Problem.new(
          id: "#{id()}:idle:#{repo.name}",
          severity: :warning,
          category: :routing,
          title: "#{repo.name}'s route matched no ticket in 24 hours",
          consequence:
            "Its polls have found nothing in the states Symphony works on since #{iso8601(since)}. " <>
              "If the route is wrong, no ticket reaches #{repo.name}; if there is simply no work, nothing is broken.",
          repos: [repo.name],
          details: [Route: describe_route(repo), "Nothing since": iso8601(since)]
        )
      ]
    else
      []
    end
  end

  defp idle(_poll, _now), do: []

  defp describe_route(repo) do
    [
      repo.team && "team #{repo.team}",
      repo.projects != [] && "projects #{Enum.join(repo.projects, ", ")}",
      repo.labels != [] && "labels #{Enum.join(repo.labels, ", ")}",
      repo.assignee && "assignee #{repo.assignee}"
    ]
    |> Enum.filter(&is_binary/1)
    |> case do
      [] -> "no route of its own (the tracker's scope)"
      parts -> Enum.join(parts, "; ")
    end
  end

  defp projects_path(repo), do: "repositories[#{repo.name}].route.projects"

  defp listed(issues), do: issues |> Enum.take(@listed_tickets) |> Enum.map(&%{identifier: &1.identifier, url: &1.url})

  defp tickets(1), do: "1 ticket"
  defp tickets(count), do: "#{count} tickets"

  defp join([first, second]), do: "#{first} and #{second}"
  defp join(names), do: "#{names |> Enum.drop(-1) |> Enum.join(", ")} and #{List.last(names)}"

  defp iso8601(at), do: at |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
