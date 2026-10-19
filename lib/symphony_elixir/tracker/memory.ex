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
  objects (optionally with a `"team"` key and a `"project"`, a name or an
  `{"id", "name", "slugId"}` object), so a release binary (the menu bar app's end-to-end test) can run
  against a fake Linear whose issues the test edits while Symphony runs.
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
    {:ok, Enum.filter(issue_entries(), &Resolver.matches?(&1, repo))}
  end

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

  @spec create_workflow_state(String.t(), String.t(), String.t()) :: {:ok, Tracker.workflow_state()} | {:error, term()}
  def create_workflow_state(state_name, team, _color) when is_binary(state_name) and is_binary(team) do
    case next_result(:memory_tracker_create_workflow_state_result) do
      :ok ->
        state = %{id: "state:#{team}:#{state_name}", name: state_name, team_id: team, team_key: team}
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

  @doc """
  The projects `refs` names by name, slug id or id: the `Tracker.project()` maps a test seeds in
  `:memory_tracker_projects`, else the projects of the issues, each in the teams of its issues. Each
  call sends `{:memory_tracker_fetch_projects, refs}`.
  """
  @spec fetch_projects([String.t()]) :: {:ok, [Tracker.project()]} | {:error, term()}
  def fetch_projects(refs) when is_list(refs) do
    send_event({:memory_tracker_fetch_projects, refs})

    case Application.get_env(:symphony_elixir, :memory_tracker_projects) do
      {:error, _reason} = error -> error
      nil -> {:ok, Enum.filter(issue_projects(), &named?(&1, refs))}
      projects -> {:ok, Enum.filter(projects, &named?(&1, refs))}
    end
  end

  defp issue_projects do
    issue_entries()
    |> Enum.filter(&is_map(&1.project))
    |> Enum.group_by(&Map.take(&1.project, [:id, :name, :slug_id]))
    |> Enum.map(fn {project, issues} ->
      team_keys = issues |> Enum.map(&(&1.team && &1.team.key)) |> Enum.filter(&is_binary/1) |> Enum.uniq()
      %{id: project[:id], name: project[:name], slug_id: project[:slug_id], team_keys: team_keys}
    end)
  end

  defp named?(project, refs), do: Enum.any?([project[:id], project[:name], project[:slug_id]], &(is_binary(&1) and &1 in refs))

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

  defp issues_from_file do
    case Config.settings() do
      {:ok, %{tracker: %{memory_issues_file: path}}} when is_binary(path) -> read_issues_file(path)
      _settings -> []
    end
  end

  defp read_issues_file(path) do
    with {:ok, body} <- File.read(path),
         {:ok, entries} when is_list(entries) <- Jason.decode(body) do
      Enum.flat_map(entries, &issue_from_json/1)
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
        team: json_team(Map.get(entry, "team")),
        project: json_project(Map.get(entry, "project"))
      }
    ]
  end

  defp issue_from_json(_entry), do: []

  defp json_team(key) when is_binary(key), do: %{key: key, name: nil}
  defp json_team(_team), do: nil

  defp json_project(name) when is_binary(name), do: %{id: nil, name: name, slug_id: nil}
  defp json_project(%{} = project), do: %{id: project["id"], name: project["name"], slug_id: project["slugId"]}
  defp json_project(_project), do: nil

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
