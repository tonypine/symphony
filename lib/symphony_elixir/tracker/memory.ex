defmodule SymphonyElixir.Tracker.Memory do
  @moduledoc """
  In-memory tracker adapter used for tests and local development.

  Each fetch/create function calls `maybe_sleep/1`, which is a test-only seam:
  tests can set `Application.put_env(:symphony_elixir, <key>, ms)` to simulate
  slow tracker I/O and exercise the orchestrator's async-task paths
  (e.g. snapshot responsiveness while a Linear call is in flight). In
  production this module is unused, and with no env set the sleep is a no-op.

  The issues come from `:memory_tracker_issues` when it is set. Otherwise they
  are read on every fetch from the JSON file `issues.memory.issues_file` names, a
  list of `{"id", "identifier", "state", "title", "description", "labels"}`
  objects (with an optional `"team": {"key", "name"}` and
  `"project": {"id", "name", "slug_id"}`), so a release binary (the menu bar app's
  end-to-end test) can run against a fake Linear whose issues the test edits while
  Symphony runs. Entries with `"kind": "project"` or `"kind": "team"` are the
  workspace's projects and teams instead (`projects_and_teams/0`); a project's
  optional `"teams"` lists its team keys.
  """

  @behaviour SymphonyElixir.Tracker

  require Logger

  alias SymphonyElixir.Config
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Routing.Resolver
  alias SymphonyElixir.Tracker

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    maybe_sleep(:memory_tracker_fetch_candidate_sleep_ms)
    {:ok, issue_entries()}
  end

  @spec fetch_candidate_issues_for_repo(term()) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues_for_repo(repo) do
    maybe_sleep(:memory_tracker_fetch_candidate_sleep_ms)
    repo = with_named_projects(repo)
    {:ok, Enum.filter(issue_entries(), &Resolver.matches?(&1, repo))}
  end

  # Linear filters a route's projects on its side, by id, slug id or name, so a route value polls
  # the issues of the project it names however little of that project the issue itself carries.
  defp with_named_projects(%{projects: [_ | _] = values} = repo) do
    named =
      for project <- List.wrap(catalog(:memory_tracker_projects_list, "project")),
          is_map(project),
          Enum.any?(values, &(&1 in project_names(project))),
          name <- project_names(project),
          do: name

    %{repo | projects: Enum.uniq(values ++ named)}
  end

  defp with_named_projects(repo), do: repo

  defp project_names(project), do: Enum.filter([project[:id], project[:slug_id], project[:name]], &is_binary/1)

  @spec fetch_issue_by_identifier(String.t()) :: {:ok, Issue.t()} | {:error, term()}
  def fetch_issue_by_identifier(identifier) when is_binary(identifier) do
    maybe_sleep(:memory_tracker_fetch_states_sleep_ms)

    issue =
      Enum.find(issue_entries(), fn %Issue{id: id, identifier: issue_identifier} ->
        identifier in [id, issue_identifier]
      end)

    case issue do
      %Issue{} = issue -> {:ok, issue}
      nil -> {:error, :issue_not_found}
    end
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) do
    maybe_sleep(:memory_tracker_fetch_states_sleep_ms)

    normalized_states =
      state_names
      |> Enum.map(&normalize_state/1)
      |> MapSet.new()

    {:ok,
     Enum.filter(issue_entries(), fn %Issue{state: state} ->
       MapSet.member?(normalized_states, normalize_state(state))
     end)}
  end

  @doc "Reports the repos named in `:memory_tracker_failed_repos` (`{name, reason}`) as failed reads."
  @spec fetch_issues_by_states_with_failures([String.t()]) :: {:ok, [Issue.t()], [{String.t(), term()}]}
  def fetch_issues_by_states_with_failures(state_names) do
    {:ok, issues} = fetch_issues_by_states(state_names)
    {:ok, issues, Application.get_env(:symphony_elixir, :memory_tracker_failed_repos, [])}
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) do
    maybe_sleep(:memory_tracker_fetch_states_sleep_ms)
    send_event({:memory_tracker_fetch_issue_states_by_ids, issue_ids})
    wanted_ids = MapSet.new(issue_ids)

    case Application.get_env(:symphony_elixir, :memory_tracker_fetch_issue_states_result) do
      {:error, _reason} = error ->
        error

      _ ->
        {:ok,
         Enum.filter(issue_entries(), fn %Issue{id: id} ->
           MapSet.member?(wanted_ids, id)
         end)}
    end
  end

  @spec enrich_issue(Issue.t()) :: {:ok, Issue.t()} | {:error, term()}
  def enrich_issue(issue), do: {:ok, issue}

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) do
    maybe_sleep(:memory_tracker_create_comment_sleep_ms)

    case next_result(:memory_tracker_create_comment_result) do
      :ok ->
        send_event({:memory_tracker_comment, issue_id, body})
        :ok

      error ->
        error
    end
  end

  @spec fetch_issue_description(String.t()) :: {:ok, String.t() | nil} | {:error, term()}
  def fetch_issue_description(issue_id) do
    case Enum.find(issue_entries(), &(&1.id == issue_id)) do
      %Issue{description: description} -> {:ok, description}
      nil -> {:error, :issue_not_found}
    end
  end

  @doc """
  Writes the description of an issue in `:memory_tracker_issues`, so the next read sees it, and
  reports `{:memory_tracker_description_update, issue_id, description}`.
  """
  @spec update_issue_description(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_description(issue_id, description) do
    case next_result(:memory_tracker_update_issue_description_result) do
      :ok ->
        put_description(issue_id, description)
        send_event({:memory_tracker_description_update, issue_id, description})
        :ok

      {:error, _reason} = error ->
        error
    end
  end

  defp put_description(issue_id, description) do
    case Application.fetch_env(:symphony_elixir, :memory_tracker_issues) do
      {:ok, issues} when is_list(issues) ->
        Application.put_env(:symphony_elixir, :memory_tracker_issues, Enum.map(issues, &with_description(&1, issue_id, description)))

      _file_or_none ->
        :ok
    end
  end

  defp with_description(%Issue{id: issue_id} = issue, issue_id, description), do: %{issue | description: description}
  defp with_description(issue, _issue_id, _description), do: issue

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name) do
    case next_result(:memory_tracker_update_issue_state_result) do
      :ok ->
        send_event({:memory_tracker_state_update, issue_id, state_name})
        :ok

      {:error, _reason} = error ->
        error
    end
  end

  @spec add_issue_label(String.t(), String.t()) :: :ok | {:error, term()}
  def add_issue_label(issue_id, label_name) do
    event = {:memory_tracker_label_added, issue_id, label_name}

    update_issue_labels(:memory_tracker_add_issue_label_result, event, issue_id, fn labels ->
      if Enum.any?(labels, &same_label?(&1, label_name)), do: labels, else: labels ++ [label_name]
    end)
  end

  @spec remove_issue_label(String.t(), String.t()) :: :ok | {:error, term()}
  def remove_issue_label(issue_id, label_name) do
    event = {:memory_tracker_label_removed, issue_id, label_name}

    update_issue_labels(:memory_tracker_remove_issue_label_result, event, issue_id, fn labels ->
      Enum.reject(labels, &same_label?(&1, label_name))
    end)
  end

  @spec fetch_breakdown_history(String.t()) :: {:ok, SymphonyElixir.Tracker.breakdown_history()} | {:error, term()}
  def fetch_breakdown_history(issue_id) do
    send_event({:memory_tracker_breakdown_history, issue_id})

    case Application.get_env(:symphony_elixir, :memory_tracker_breakdown_histories, %{}) do
      {:error, _reason} = error -> error
      histories -> {:ok, Map.get(histories, issue_id, %{state_changes: [], sub_issues: []})}
    end
  end

  @spec fetch_plan_comments(String.t()) :: {:ok, SymphonyElixir.PlanComments.feedback()} | {:error, term()}
  def fetch_plan_comments(issue_id) do
    send_event({:memory_tracker_plan_comments, issue_id})

    case Application.get_env(:symphony_elixir, :memory_tracker_plan_comments, %{}) do
      {:error, _reason} = error -> error
      feedback -> {:ok, Map.get(feedback, issue_id, %{state_changes: [], comments: []})}
    end
  end

  @spec create_reply(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def create_reply(issue_id, parent_comment_id, body) do
    case next_result(:memory_tracker_create_comment_result) do
      :ok ->
        send_event({:memory_tracker_reply, issue_id, parent_comment_id, body})
        :ok

      error ->
        error
    end
  end

  @spec workflow_state_exists?(String.t(), [String.t()]) :: {:ok, boolean()} | {:error, term()}
  def workflow_state_exists?(state_name, _teams) do
    case Application.get_env(:symphony_elixir, :memory_tracker_workflow_states) do
      nil -> {:ok, true}
      {:error, _reason} = error -> error
      states when is_list(states) -> {:ok, normalize_state(state_name) in Enum.map(states, &normalize_state/1)}
    end
  end

  @doc """
  The workflow states a test seeds in `:memory_tracker_workflow_states_list`, and the ones
  `create_workflow_state/3` has added.
  """
  @spec workflow_states() :: {:ok, [Tracker.workflow_state()]} | {:error, term()}
  def workflow_states do
    case Application.get_env(:symphony_elixir, :memory_tracker_workflow_states_list) do
      nil -> {:ok, []}
      {:error, _reason} = error -> error
      states when is_list(states) -> {:ok, states}
    end
  end

  @spec create_workflow_state(String.t(), String.t(), String.t(), keyword()) :: Tracker.created_state()
  def create_workflow_state(state_name, team, _color, opts \\ []) when is_binary(state_name) and is_binary(team) do
    case next_result(:memory_tracker_create_workflow_state_result) do
      :ok ->
        state = %{
          id: "state:#{team}:#{state_name}",
          name: state_name,
          team_id: team,
          team_key: team,
          type: Keyword.get(opts, :type) || "started",
          position: Keyword.get(opts, :position)
        }

        put_env_list(:memory_tracker_workflow_states_list, state)
        send_event({:memory_tracker_created_workflow_state, state_name, team})
        {:ok, state}

      {:error, _reason} = error ->
        error
    end
  end

  @doc "The labels a test seeds in `:memory_tracker_labels_list`, and the ones `create_label/2` has added."
  @spec labels() :: {:ok, [Tracker.label()]} | {:error, term()}
  def labels do
    case Application.get_env(:symphony_elixir, :memory_tracker_labels_list) do
      nil -> {:ok, []}
      {:error, _reason} = error -> error
      labels when is_list(labels) -> {:ok, labels}
    end
  end

  @doc """
  The seeded workflow states of the team `team` (by key or id). Each call sends
  `{:memory_tracker_team_workflow_states, team}`, so a test can count requests.
  """
  @spec team_workflow_states(String.t()) :: {:ok, [Tracker.workflow_state()]} | {:error, term()}
  def team_workflow_states(team) when is_binary(team) do
    send_event({:memory_tracker_team_workflow_states, team})
    with {:ok, states} <- workflow_states(), do: {:ok, Enum.filter(states, &in_team?(&1, team))}
  end

  @doc """
  The seeded labels the team `team` can use: its own and the workspace's (no team). Each call sends
  `{:memory_tracker_team_labels, team}`.
  """
  @spec team_labels(String.t()) :: {:ok, [Tracker.label()]} | {:error, term()}
  def team_labels(team) when is_binary(team) do
    send_event({:memory_tracker_team_labels, team})
    with {:ok, labels} <- labels(), do: {:ok, Enum.filter(labels, &(workspace_label?(&1) or in_team?(&1, team)))}
  end

  defp in_team?(item, team), do: team in [Map.get(item, :team_key), Map.get(item, :team_id)]

  defp workspace_label?(label), do: is_nil(Map.get(label, :team_key)) and is_nil(Map.get(label, :team_id))

  @doc """
  The projects and teams a test seeds in `:memory_tracker_projects_list` and
  `:memory_tracker_teams_list` (or `{:error, reason}` in either), else the entries of the issues
  file with `"kind": "project"` (`id`, `name`, `slug_id`, `teams`) or `"kind": "team"` (`id`, `key`,
  `name`). A project that names no teams is in the teams of its issues. Each call sends
  `{:memory_tracker_projects_and_teams}`, so a test can count requests.
  """
  @spec projects_and_teams() :: {:ok, Tracker.projects_and_teams()} | {:error, term()}
  def projects_and_teams do
    send_event({:memory_tracker_projects_and_teams})

    case {catalog(:memory_tracker_projects_list, "project"), catalog(:memory_tracker_teams_list, "team")} do
      {{:error, _reason} = error, _teams} -> error
      {_projects, {:error, _reason} = error} -> error
      {projects, teams} -> {:ok, %{projects: Enum.map(projects, &with_team_keys/1), teams: teams}}
    end
  end

  defp with_team_keys(project), do: Map.put_new_lazy(project, :team_keys, fn -> issue_team_keys(project) end)

  defp issue_team_keys(project) do
    names = project_names(project)

    for %Issue{project: %{} = issue_project, team: %{key: key}} <- issue_entries(),
        is_binary(key),
        Enum.any?(project_names(issue_project), &(&1 in names)),
        uniq: true,
        do: key
  end

  defp catalog(key, kind) do
    case Application.fetch_env(:symphony_elixir, key) do
      {:ok, entries} -> entries
      :error -> Enum.flat_map(file_entries(), &catalog_entry(&1, kind))
    end
  end

  defp catalog_entry(%{"kind" => "project", "teams" => teams} = entry, "project") when is_list(teams),
    do: [%{id: entry["id"], name: entry["name"], slug_id: entry["slug_id"], team_keys: Enum.filter(teams, &is_binary/1)}]

  defp catalog_entry(%{"kind" => "project"} = entry, "project"), do: [%{id: entry["id"], name: entry["name"], slug_id: entry["slug_id"]}]
  defp catalog_entry(%{"kind" => "team"} = entry, "team"), do: [%{id: entry["id"], key: entry["key"], name: entry["name"]}]
  defp catalog_entry(_entry, _kind), do: []

  @spec create_label(String.t(), String.t()) :: {:ok, Tracker.label()} | {:error, term()}
  def create_label(label_name, team) when is_binary(label_name) and is_binary(team) do
    case next_result(:memory_tracker_create_label_result) do
      :ok ->
        label = %{id: "label:#{team}:#{label_name}", name: label_name, team_id: team}
        put_env_list(:memory_tracker_labels_list, label)
        send_event({:memory_tracker_created_label, label_name, team})
        {:ok, label}

      {:error, _reason} = error ->
        error
    end
  end

  defp put_env_list(key, value) do
    Application.put_env(:symphony_elixir, key, List.wrap(Application.get_env(:symphony_elixir, key)) ++ [value])
  end

  # Edits the labels where the issues come from, `:memory_tracker_issues` or the issues file, so the
  # next fetch sees them.
  defp update_issue_labels(result_key, event, issue_id, update) do
    case next_result(result_key) do
      :ok ->
        put_issue_labels(issue_id, update)
        send_event(event)
        :ok

      {:error, _reason} = error ->
        error
    end
  end

  defp put_issue_labels(issue_id, update) do
    case Application.fetch_env(:symphony_elixir, :memory_tracker_issues) do
      {:ok, issues} ->
        issues = Enum.map(issues, &update_labels(&1, issue_id, update))
        Application.put_env(:symphony_elixir, :memory_tracker_issues, issues)

      :error ->
        put_file_issue_labels(issue_id, update)
    end
  end

  defp put_file_issue_labels(issue_id, update) do
    with {:ok, %{tracker: %{memory_issues_file: path}}} when is_binary(path) <- Config.settings(),
         {:ok, body} <- File.read(path),
         {:ok, entries} when is_list(entries) <- Jason.decode(body) do
      entries =
        Enum.map(entries, fn
          %{"id" => ^issue_id} = entry -> Map.put(entry, "labels", update.(Enum.filter(List.wrap(entry["labels"]), &is_binary/1)))
          entry -> entry
        end)

      File.write!(path, Jason.encode!(entries, pretty: true))
    end

    :ok
  end

  defp update_labels(%Issue{id: issue_id, labels: labels} = issue, issue_id, update), do: %{issue | labels: update.(labels)}
  defp update_labels(issue, _issue_id, _update), do: issue

  defp same_label?(label, label_name), do: normalize_state(label) == normalize_state(label_name)

  # A list of results answers one call each, then `:ok`, so a test can script a failure
  # followed by a success.
  defp next_result(key) do
    case Application.get_env(:symphony_elixir, key, :ok) do
      [result | rest] ->
        Application.put_env(:symphony_elixir, key, rest)
        result

      [] ->
        :ok

      result ->
        result
    end
  end

  defp configured_issues do
    case Application.fetch_env(:symphony_elixir, :memory_tracker_issues) do
      {:ok, issues} -> issues
      :error -> issues_from_file()
    end
  end

  defp issues_from_file, do: Enum.flat_map(file_entries(), &issue_from_json/1)

  defp file_entries do
    case Config.settings() do
      {:ok, %{tracker: %{memory_issues_file: path}}} when is_binary(path) -> read_issues_file(path)
      _settings -> []
    end
  end

  defp read_issues_file(path) do
    with {:ok, body} <- File.read(path),
         {:ok, entries} when is_list(entries) <- Jason.decode(body) do
      entries
    else
      error ->
        Logger.warning("Memory tracker could not read issues_file=#{path}: #{inspect(error)}")
        []
    end
  end

  defp issue_from_json(%{"id" => id, "identifier" => identifier, "state" => state} = entry)
       when is_binary(id) and is_binary(identifier) and is_binary(state) do
    [
      %Issue{
        id: id,
        identifier: identifier,
        state: state,
        title: Map.get(entry, "title"),
        description: Map.get(entry, "description"),
        labels: Enum.filter(List.wrap(Map.get(entry, "labels")), &is_binary/1),
        team: json_map(entry["team"], key: "key", name: "name"),
        project: json_map(entry["project"], id: "id", name: "name", slug_id: "slug_id")
      }
    ]
  end

  defp issue_from_json(_entry), do: []

  # The team (`key`, `name`) or project (`id`, `name`, `slug_id`) of an issues-file entry.
  defp json_map(%{} = value, fields), do: Map.new(fields, fn {field, key} -> {field, value[key]} end)
  defp json_map(_value, _fields), do: nil

  defp issue_entries do
    Enum.filter(configured_issues(), &match?(%Issue{}, &1))
  end

  defp send_event(message) do
    case Application.get_env(:symphony_elixir, :memory_tracker_recipient) do
      pid when is_pid(pid) -> send(pid, message)
      _ -> :ok
    end
  end

  defp maybe_sleep(key) do
    case Application.get_env(:symphony_elixir, key, 0) do
      ms when is_integer(ms) and ms > 0 -> Process.sleep(ms)
      _ -> :ok
    end
  end

  defp normalize_state(state) when is_binary(state) do
    state
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_state(_state), do: ""
end
