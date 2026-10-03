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
  objects, so a release binary (the menu bar app's end-to-end test) can run
  against a fake Linear whose issues the test edits while Symphony runs.
  """

  @behaviour SymphonyElixir.Tracker

  require Logger

  alias SymphonyElixir.Config
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Routing.Resolver

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

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) do
    maybe_sleep(:memory_tracker_fetch_states_sleep_ms)
    wanted_ids = MapSet.new(issue_ids)

    {:ok,
     Enum.filter(issue_entries(), fn %Issue{id: id} ->
       MapSet.member?(wanted_ids, id)
     end)}
  end

  @spec enrich_issue(Issue.t()) :: {:ok, Issue.t()} | {:error, term()}
  def enrich_issue(issue), do: {:ok, issue}

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) do
    maybe_sleep(:memory_tracker_create_comment_sleep_ms)

    case Application.get_env(:symphony_elixir, :memory_tracker_create_comment_result, :ok) do
      :ok ->
        send_event({:memory_tracker_comment, issue_id, body})
        :ok

      error ->
        error
    end
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name) do
    case Application.get_env(:symphony_elixir, :memory_tracker_update_issue_state_result, :ok) do
      :ok ->
        send_event({:memory_tracker_state_update, issue_id, state_name})
        :ok

      {:error, _reason} = error ->
        error
    end
  end

  @spec fetch_breakdown_history(String.t()) :: {:ok, SymphonyElixir.Tracker.breakdown_history()} | {:error, term()}
  def fetch_breakdown_history(issue_id) do
    send_event({:memory_tracker_breakdown_history, issue_id})

    case Application.get_env(:symphony_elixir, :memory_tracker_breakdown_histories, %{}) do
      {:error, _reason} = error -> error
      histories -> {:ok, Map.get(histories, issue_id, %{state_changes: [], sub_issues: []})}
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
        labels: Enum.filter(List.wrap(Map.get(entry, "labels")), &is_binary/1)
      }
    ]
  end

  defp issue_from_json(_entry), do: []

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
