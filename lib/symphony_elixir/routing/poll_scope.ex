defmodule SymphonyElixir.Routing.PollScope do
  @moduledoc """
  Which repo's poll reads an issue, decided from the issue's own fields: the scope each repo polls
  with (`SymphonyElixir.Linear.Client.repo_scope_filter/1`): its route's team, projects, labels and
  assignee, else the tracker's `team`, `project_slug`, `labels` and `assignee`. It files a ticket no
  read has filed yet, such as a new ticket's webhook delivery, under the repo whose poll would.

  The poll reads each repo's scope on its own and counts a ticket two repos return as a conflict, so
  a default repo takes nothing here a scoped repo also takes (unlike
  `SymphonyElixir.Routing.Resolver`): an issue is routed only when exactly one repo's scope takes it.

  An issue is routed only when every repo's answer is certain. A repo whose scope the issue's fields
  can't be compared with leaves it unrouted: one assigned to `me` before a poll learned whose key it
  is, a team named by its id (a delivery's team carries its key), a project named while the issue's
  project carries neither its slug nor its URL, or a repo whose settings can't be read.
  """

  alias SymphonyElixir.Config
  alias SymphonyElixir.Linear.{Client, Issue}

  @id_pattern ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
  @slug_id_pattern ~r/^[0-9a-f]{12}$/

  @doc """
  The key of the one repo of `repos` whose poll scope takes `issue`, or `:unrouted` when none, several,
  or any whose answer is uncertain does. `opts`:

  - `:tracker_settings` — a function from a repo key to `{:ok, tracker}` (the repo's `tracker`
    settings), defaulting to the repo's settings
  - `:viewer_id` — a function giving the id of the API key's user, or nil while no poll learned it,
    defaulting to `SymphonyElixir.Linear.Client.known_viewer_id/0`
  """
  @spec route(Issue.t(), [map()], keyword()) :: {:ok, String.t()} | :unrouted
  def route(%Issue{} = issue, repos, opts \\ []) when is_list(repos) do
    tracker_fun = Keyword.get(opts, :tracker_settings, &tracker/1)
    viewer_fun = Keyword.get(opts, :viewer_id, &Client.known_viewer_id/0)

    repos
    |> Enum.reduce_while([], fn repo, taken ->
      case takes(repo, issue, tracker_fun, viewer_fun) do
        {:ok, true} -> {:cont, [repo.name | taken]}
        {:ok, false} -> {:cont, taken}
        :uncertain -> {:halt, :uncertain}
      end
    end)
    |> case do
      [repo_key] -> {:ok, repo_key}
      _none_several_or_uncertain -> :unrouted
    end
  end

  defp takes(%{name: name} = repo, issue, tracker_fun, viewer_fun) when is_binary(name) do
    with name when is_binary(name) <- present(name) || {:ok, false},
         {:ok, tracker} <- tracker_fun.(name),
         {:ok, team?} <- team?(issue, present(Map.get(repo, :team)) || present(tracker.team)),
         {:ok, project?} <- project?(issue, list(Map.get(repo, :projects)), present(tracker.project_slug)),
         {:ok, assignee?} <- assignee?(issue, present(Map.get(repo, :assignee)) || present(tracker.assignee), viewer_fun) do
      {:ok, team? and project? and assignee? and labels?(issue, list(Map.get(repo, :labels)), list(tracker.labels))}
    else
      {:ok, false} -> {:ok, false}
      _uncertain -> :uncertain
    end
  end

  defp takes(_repo, _issue, _tracker_fun, _viewer_fun), do: {:ok, false}

  defp team?(_issue, nil), do: {:ok, true}

  defp team?(issue, team) do
    if Regex.match?(@id_pattern, team), do: :uncertain, else: {:ok, match?(%{key: ^team}, issue.team)}
  end

  # The poll matches `projects` by name, slug or id, else the tracker's `project_slug` by slug.
  defp project?(_issue, [], nil), do: {:ok, true}
  defp project?(%Issue{project: nil}, _projects, _slug), do: {:ok, false}
  defp project?(issue, [], slug), do: slug?(issue.project, [slug])

  defp project?(%Issue{project: project}, projects, _slug) do
    if Enum.any?([Map.get(project, :name), Map.get(project, :id)], &(&1 in projects)), do: {:ok, true}, else: slug?(project, projects)
  end

  defp slug?(project, slugs) do
    case slugs(project) do
      [] -> :uncertain
      known -> {:ok, Enum.any?(known, &(&1 in Enum.flat_map(slugs, fn slug -> [slug | slug_ids(slug)] end)))}
    end
  end

  # A delivery's project has no `slugId` but its URL, `.../project/<name>-<slugId>`: a route names a
  # project by that last part or by the slug id alone, so either side is compared by both.
  defp slugs(project) do
    from_url =
      case Map.get(project, :url) do
        url when is_binary(url) -> url |> URI.parse() |> Map.get(:path) |> to_string() |> String.split("/", trim: true) |> Enum.take(-1)
        _no_url -> []
      end

    named = List.wrap(present(Map.get(project, :slug_id))) ++ from_url
    Enum.uniq(named ++ Enum.flat_map(named, &slug_ids/1))
  end

  defp slug_ids(slug) do
    slug_id = slug |> String.split("-") |> List.last()
    if slug_id != slug and Regex.match?(@slug_id_pattern, slug_id), do: [slug_id], else: []
  end

  defp assignee?(_issue, nil, _viewer_fun), do: {:ok, true}

  defp assignee?(issue, "me", viewer_fun) do
    case viewer_fun.() do
      viewer_id when is_binary(viewer_id) -> {:ok, issue.assignee_id == viewer_id}
      _unknown -> :uncertain
    end
  end

  defp assignee?(issue, assignee, _viewer_fun), do: {:ok, issue.assignee_id == assignee}

  # The route's labels must all be on the issue; the tracker's, which apply when the route names
  # none, any of them. Labels are compared without case, as an issue keeps them.
  defp labels?(_issue, [], []), do: true
  defp labels?(issue, [], tracker_labels), do: Enum.any?(downcase(tracker_labels), &(&1 in labels(issue)))
  defp labels?(issue, labels, _tracker_labels), do: Enum.all?(downcase(labels), &(&1 in labels(issue)))

  defp labels(%Issue{labels: labels}) when is_list(labels), do: downcase(labels)
  defp labels(_issue), do: []

  defp downcase(values), do: Enum.map(values, &String.downcase/1)

  defp tracker(repo_key) do
    with {:ok, settings} <- Config.settings_for_repo(repo_key), do: {:ok, settings.tracker}
  end

  defp list(values) when is_list(values), do: values |> Enum.map(&present(to_string(&1))) |> Enum.reject(&is_nil/1)
  defp list(value) when is_binary(value), do: list([value])
  defp list(_value), do: []

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present(_value), do: nil
end
