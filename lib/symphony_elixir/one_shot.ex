defmodule SymphonyElixir.OneShot do
  @moduledoc """
  Synchronous single-issue runner used by `symphony run`.
  """

  require Logger
  import Bitwise, only: [<<<: 2]

  alias SymphonyElixir.{
    AgentRunner,
    Config,
    Linear.Issue,
    Routing.Resolver,
    RunStore,
    Tracker,
    URLUtils,
    Verification,
    Workspace
  }

  alias SymphonyElixir.Config.SystemSchema

  @default_max_attempts 4
  @failure_retry_base_ms 10_000
  @task_shutdown_timeout_ms 5_000

  @type result :: {:ok, map()} | {:error, term()} | {:config_error, term()} | {:timeout, term()}
  @type deps :: %{
          optional(:start_runtime) => (-> :ok | {:error, term()}),
          optional(:fetch_issue) => (String.t() -> {:ok, Issue.t()} | {:error, term()}),
          optional(:repos) => (-> {:ok, [SystemSchema.Repo.t() | map()]} | {:error, term()}),
          optional(:settings_for_repo) => (String.t() | nil -> {:ok, Config.Schema.t()} | {:error, term()}),
          optional(:ensure_verification_runtime) => (String.t() | nil -> :ok | {:error, term()}),
          optional(:start_agent_task) => (Issue.t(), pid(), keyword() -> Task.t()),
          optional(:shutdown_task) => (Task.t(), timeout() -> term()),
          optional(:run_store) => module(),
          optional(:sleep) => (non_neg_integer() -> :ok),
          optional(:monotonic_time) => (-> integer())
        }

  @spec run(String.t(), keyword()) :: result()
  def run(issue_identifier, opts \\ [])

  @spec run(String.t(), keyword()) :: result()
  def run(issue_identifier, opts) when is_binary(issue_identifier) and is_list(opts) do
    deps = opts |> Keyword.get(:deps, %{}) |> runtime_deps()

    with :ok <- deps.start_runtime.(),
         {:ok, %Issue{} = issue} <- resolve_issue(issue_identifier, deps),
         :ok <- deps.ensure_verification_runtime.(issue.repo_key),
         {:ok, settings} <- deps.settings_for_repo.(issue.repo_key) do
      run_with_retries(issue, settings, deps, opts)
    else
      {:config_error, reason} -> {:config_error, reason}
      {:error, {:invalid_workflow_config, _message} = reason} -> {:config_error, reason}
      {:error, {:invalid_symphony_config, _message} = reason} -> {:config_error, reason}
      {:error, reason} -> {:error, reason}
    end
  rescue
    exception in [ArgumentError] ->
      {:config_error, Exception.message(exception)}
  end

  def run(_issue_identifier, _opts), do: {:error, :invalid_issue_identifier}

  @spec start_minimal_runtime() :: :ok | {:error, term()}
  def start_minimal_runtime do
    previous_disable = System.get_env("SYMPHONY_DISABLE_ORCHESTRATOR")
    System.put_env("SYMPHONY_DISABLE_ORCHESTRATOR", "true")

    try do
      with :ok <- SymphonyElixir.LogFile.configure(),
           :ok <- Config.validate_repo_workflows(),
           {:ok, _started_apps} <- Application.ensure_all_started(:symphony_elixir) do
        RunStore.ensure_started()
      end
    after
      restore_env("SYMPHONY_DISABLE_ORCHESTRATOR", previous_disable)
    end
  end

  @spec ensure_verification_runtime(String.t() | nil) :: :ok | {:error, term()}
  def ensure_verification_runtime(repo_key) do
    with {:ok, settings} <- Config.settings_for_repo(repo_key) do
      settings |> Verification.child_specs_for_runtime() |> ensure_verification_children_started()
    end
  end

  defp ensure_verification_children_started(child_specs) do
    Enum.reduce_while(child_specs, :ok, fn child_spec, :ok ->
      case ensure_supervised_child_started(child_spec) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp runtime_deps(overrides) when is_map(overrides) do
    Map.merge(
      %{
        start_runtime: &start_minimal_runtime/0,
        fetch_issue: &Tracker.fetch_issue_by_identifier/1,
        repos: &Config.repos/0,
        settings_for_repo: &Config.settings_for_repo/1,
        ensure_verification_runtime: &ensure_verification_runtime/1,
        start_agent_task: &start_agent_task/3,
        shutdown_task: &Task.shutdown/2,
        run_store: RunStore,
        sleep: fn ms -> Process.sleep(ms) end,
        monotonic_time: fn -> System.monotonic_time(:millisecond) end
      },
      overrides
    )
  end

  defp resolve_issue(issue_identifier, deps) do
    with {:ok, %Issue{} = issue} <- deps.fetch_issue.(issue_identifier),
         {:ok, repos} <- deps.repos.() do
      route_issue(issue, repos)
    end
  end

  defp route_issue(%Issue{} = issue, repos) when is_list(repos) do
    case Resolver.resolve(issue, repos) do
      {:matched, repo} ->
        {:ok, %{issue | repo_key: repo_name(repo)}}

      {:conflict, repos} ->
        {:error, {:ambiguous_repo_route, issue.identifier || issue.id, Enum.map(repos, &repo_name/1)}}

      :unmatched ->
        {:error, {:repo_route_not_found, issue.identifier || issue.id}}
    end
  end

  defp run_with_retries(%Issue{} = issue, settings, deps, opts) do
    max_attempts = max_attempts(opts)
    deadline_ms = deadline_ms(Keyword.get(opts, :timeout_ms), deps)

    case deadline_ms do
      {:error, reason} -> {:config_error, reason}
      deadline_ms -> run_with_retries(issue, settings, deps, opts, 1, max_attempts, deadline_ms, nil)
    end
  end

  defp run_with_retries(_issue, _settings, _deps, _opts, attempt, max_attempts, _deadline_ms, last_error)
       when attempt > max_attempts do
    {:error, last_error || :attempts_exhausted}
  end

  defp run_with_retries(issue, settings, deps, opts, attempt, max_attempts, deadline_ms, _last_error) do
    case run_attempt(issue, deps, opts, attempt, deadline_ms) do
      {:ok, record} ->
        {:ok, record}

      {:timeout, reason} ->
        {:timeout, reason}

      {:error, reason} ->
        if attempt >= max_attempts do
          {:error, reason}
        else
          sleep_before_retry(settings, deps, opts, attempt, deadline_ms)
          run_with_retries(issue, settings, deps, opts, attempt + 1, max_attempts, deadline_ms, reason)
        end
    end
  end

  defp run_attempt(%Issue{} = issue, deps, opts, attempt, deadline_ms) do
    run_id = new_run_id(issue.id)
    repo_key = issue.repo_key || Config.repo_key!()
    started_at = DateTime.utc_now()
    entry = initial_entry(issue, repo_key, run_id, attempt, started_at)
    :ok = persist_run_start(deps.run_store, entry)
    parent = self()

    task =
      deps.start_agent_task.(
        issue,
        parent,
        Keyword.merge(Keyword.get(opts, :agent_opts, []),
          attempt: attempt,
          repo_key: repo_key,
          run_id: run_id
        )
      )

    receive_attempt(task, issue, deps, entry, deadline_ms)
  end

  defp receive_attempt(%Task{ref: ref} = task, issue, deps, entry, deadline_ms) do
    timeout = receive_timeout(deadline_ms, deps)

    receive do
      {:worker_runtime_info, issue_id, runtime_info} when issue_id == issue.id and is_map(runtime_info) ->
        entry = merge_runtime_info(entry, runtime_info)

        persist_run_update(deps.run_store, entry, run_update(entry))
        receive_attempt(task, issue, deps, entry, deadline_ms)

      # A one-shot run has no no-progress watchdog, so a tool's heartbeat is dropped unrecorded.
      {:codex_worker_update, issue_id, %{event: :tool_progress}} when issue_id == issue.id ->
        receive_attempt(task, issue, deps, entry, deadline_ms)

      {:codex_worker_update, issue_id, update} when issue_id == issue.id ->
        entry = integrate_worker_update(entry, update)
        persist_run_update(deps.run_store, entry, run_update(entry))
        receive_attempt(task, issue, deps, entry, deadline_ms)

      {^ref, :ok} ->
        Process.demonitor(ref, [:flush])
        record = complete_entry(deps.run_store, entry, "success", nil)
        {:ok, record}

      {^ref, {:error, reason}} ->
        Process.demonitor(ref, [:flush])
        complete_entry(deps.run_store, entry, "failure", inspect(reason))
        {:error, reason}

      {^ref, other} ->
        Process.demonitor(ref, [:flush])
        complete_entry(deps.run_store, entry, "failure", inspect(other))
        {:error, other}

      {:DOWN, ^ref, :process, _pid, :normal} ->
        record = complete_entry(deps.run_store, entry, "success", nil)
        {:ok, record}

      {:DOWN, ^ref, :process, _pid, reason} ->
        complete_entry(deps.run_store, entry, "failure", inspect(reason))
        {:error, reason}
    after
      timeout ->
        deps.shutdown_task.(task, @task_shutdown_timeout_ms)
        entry = drain_worker_messages(entry, issue)
        cleanup_workspace(entry)
        complete_entry(deps.run_store, entry, "timeout", "one-shot timeout exceeded")
        {:timeout, :timeout_exceeded}
    end
  end

  defp drain_worker_messages(entry, issue) do
    receive do
      {:worker_runtime_info, issue_id, runtime_info} when issue_id == issue.id and is_map(runtime_info) ->
        entry
        |> merge_runtime_info(runtime_info)
        |> drain_worker_messages(issue)

      {:codex_worker_update, issue_id, %{event: :tool_progress}} when issue_id == issue.id ->
        drain_worker_messages(entry, issue)

      {:codex_worker_update, issue_id, update} when issue_id == issue.id ->
        entry
        |> integrate_worker_update(update)
        |> drain_worker_messages(issue)
    after
      0 -> entry
    end
  end

  defp merge_runtime_info(entry, runtime_info) do
    entry
    |> Map.merge(Map.take(runtime_info, [:worker_host, :workspace_path, :agent_module, :agent_session]))
    |> Map.put(:last_event_at, entry.last_event_at || DateTime.utc_now())
  end

  defp max_attempts(opts) do
    cond do
      Keyword.get(opts, :no_retry, false) -> 1
      is_integer(Keyword.get(opts, :max_attempts)) -> max(Keyword.fetch!(opts, :max_attempts), 1)
      true -> @default_max_attempts
    end
  end

  defp deadline_ms(nil, _deps), do: nil
  defp deadline_ms(:invalid, _deps), do: {:error, :invalid_timeout}
  defp deadline_ms(timeout_ms, deps) when is_integer(timeout_ms) and timeout_ms > 0, do: deps.monotonic_time.() + timeout_ms
  defp deadline_ms(_timeout_ms, _deps), do: {:error, :invalid_timeout}

  defp receive_timeout(nil, _deps), do: :infinity

  defp receive_timeout(deadline_ms, deps) when is_integer(deadline_ms) do
    max(deadline_ms - deps.monotonic_time.(), 0)
  end

  defp sleep_before_retry(settings, deps, opts, attempt, deadline_ms) do
    delay_ms = Keyword.get(opts, :retry_delay_ms, failure_retry_delay(attempt, settings))

    case remaining_ms(deadline_ms, deps) do
      nil ->
        deps.sleep.(delay_ms)

      remaining when remaining > 0 ->
        deps.sleep.(min(delay_ms, remaining))

      _ ->
        :ok
    end
  end

  defp remaining_ms(nil, _deps), do: nil
  defp remaining_ms(deadline_ms, deps) when is_integer(deadline_ms), do: deadline_ms - deps.monotonic_time.()

  defp failure_retry_delay(attempt, settings) do
    max_delay_power = min(max(attempt - 1, 0), 10)
    max_backoff_ms = get_in(settings, [Access.key(:agent), Access.key(:max_retry_backoff_ms)]) || 300_000
    min(@failure_retry_base_ms * (1 <<< max_delay_power), max_backoff_ms)
  end

  defp start_agent_task(%Issue{} = issue, recipient, opts) when is_pid(recipient) and is_list(opts) do
    Task.Supervisor.async_nolink(SymphonyElixir.TaskSupervisor, fn ->
      AgentRunner.run(issue, recipient, opts)
    end)
  end

  defp persist_run_start(run_store, entry) do
    entry
    |> run_record("running", nil)
    |> run_store.put_run()
    |> log_run_store_error("persist one-shot run start")
  end

  defp persist_run_update(run_store, entry, attrs) do
    entry.repo_key
    |> run_store.update_run(entry.run_id, attrs)
    |> ignore_missing_run()
    |> log_run_store_error("persist one-shot run update")
  end

  defp complete_entry(run_store, entry, status, error) do
    now = DateTime.utc_now()

    attrs =
      entry
      |> run_update()
      |> Map.merge(%{
        status: status,
        ended_at: now,
        error: error,
        runtime_seconds: runtime_seconds(entry.started_at, now),
        updated_at: now
      })

    persist_run_update(run_store, entry, attrs)
    Map.merge(run_record(entry, status, error), attrs)
  end

  defp initial_entry(%Issue{} = issue, repo_key, run_id, attempt, started_at) do
    %{
      run_id: run_id,
      repo_key: repo_key,
      issue: issue,
      issue_id: issue.id,
      identifier: issue.identifier,
      attempt: attempt,
      started_at: started_at,
      worker_host: nil,
      workspace_path: nil,
      session_id: nil,
      transcript_path: nil,
      codex_app_server_pid: nil,
      turn_count: 0,
      tokens: empty_tokens(),
      transcript_buffer: [],
      transcript_buffer_size: 0,
      last_event: nil,
      last_event_at: started_at
    }
  end

  defp run_record(entry, status, error) do
    issue = entry.issue
    now = DateTime.utc_now()

    %{
      run_id: entry.run_id,
      repo_key: entry.repo_key,
      issue_id: issue.id,
      issue_identifier: issue.identifier,
      title: issue.title,
      state: issue.state,
      status: status,
      attempt: entry.attempt,
      started_at: entry.started_at,
      ended_at: nil,
      error: error,
      worker_host: entry.worker_host,
      verification_port: nil,
      workspace_path: entry.workspace_path,
      session_id: entry.session_id,
      transcript_path: entry.transcript_path,
      codex_app_server_pid: entry.codex_app_server_pid,
      turn_count: entry.turn_count,
      tokens: entry.tokens,
      transcript_buffer: entry.transcript_buffer,
      transcript_buffer_size: entry.transcript_buffer_size,
      runtime_seconds: runtime_seconds(entry.started_at, now),
      last_event: entry.last_event,
      last_event_at: entry.last_event_at,
      pull_request_url: URLUtils.pull_request_url(entry) || URLUtils.pull_request_url(issue),
      updated_at: now
    }
  end

  defp run_update(entry) do
    %{
      worker_host: entry.worker_host,
      workspace_path: entry.workspace_path,
      session_id: entry.session_id,
      transcript_path: entry.transcript_path,
      codex_app_server_pid: entry.codex_app_server_pid,
      turn_count: entry.turn_count,
      tokens: entry.tokens,
      transcript_buffer: entry.transcript_buffer,
      transcript_buffer_size: entry.transcript_buffer_size,
      runtime_seconds: runtime_seconds(entry.started_at, DateTime.utc_now()),
      last_event: entry.last_event,
      last_event_at: entry.last_event_at,
      pull_request_url: URLUtils.pull_request_url(entry) || URLUtils.pull_request_url(entry.issue),
      updated_at: DateTime.utc_now()
    }
  end

  defp integrate_worker_update(entry, %{event: event, timestamp: timestamp} = update) do
    entry
    |> Map.put(:last_event, event)
    |> Map.put(:last_event_at, parse_update_timestamp(timestamp) || DateTime.utc_now())
    |> maybe_put_session_id(update)
    |> put_transcript_event(update)
  end

  defp integrate_worker_update(entry, update) do
    entry
    |> Map.put(:last_event, update)
    |> Map.put(:last_event_at, DateTime.utc_now())
    |> put_transcript_event(update)
  end

  defp maybe_put_session_id(entry, %{event: %{session_id: session_id}}) when is_binary(session_id) do
    Map.put(entry, :session_id, session_id)
  end

  defp maybe_put_session_id(entry, %{event: %{"session_id" => session_id}}) when is_binary(session_id) do
    Map.put(entry, :session_id, session_id)
  end

  defp maybe_put_session_id(entry, _update), do: entry

  defp put_transcript_event(entry, update) do
    transcript_buffer = Enum.take(entry.transcript_buffer ++ [update], -200)

    %{entry | transcript_buffer: transcript_buffer, transcript_buffer_size: length(transcript_buffer)}
  end

  defp cleanup_workspace(%{workspace_path: workspace, worker_host: worker_host}) when is_binary(workspace) do
    case Workspace.remove(workspace, worker_host) do
      {:ok, _removed} -> :ok
      {:error, reason, output} -> Logger.warning("One-shot timeout workspace cleanup failed: #{inspect(reason)} output=#{inspect(output)}")
    end
  end

  defp cleanup_workspace(_entry), do: :ok

  defp empty_tokens do
    %{
      input_tokens: 0,
      uncached_input_tokens: 0,
      cached_input_tokens: 0,
      cache_creation_input_tokens: 0,
      output_tokens: 0,
      total_tokens: 0
    }
  end

  defp runtime_seconds(%DateTime{} = started_at, %DateTime{} = ended_at) do
    max(DateTime.diff(ended_at, started_at, :second), 0)
  end

  defp runtime_seconds(_started_at, _ended_at), do: 0

  defp parse_update_timestamp(%DateTime{} = timestamp), do: timestamp

  defp parse_update_timestamp(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp parse_update_timestamp(_timestamp), do: nil

  defp ensure_supervised_child_started(child_spec) do
    case Process.whereis(SymphonyElixir.Supervisor) do
      pid when is_pid(pid) ->
        case Supervisor.start_child(pid, child_spec) do
          {:ok, _pid} -> :ok
          {:ok, _pid, _info} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, :already_present} -> restart_supervised_child(pid, child_id(child_spec))
          {:error, reason} -> {:error, reason}
        end

      _ ->
        {:error, :supervisor_unavailable}
    end
  end

  defp restart_supervised_child(supervisor, child_id) do
    case Supervisor.restart_child(supervisor, child_id) do
      {:ok, _pid} -> :ok
      {:ok, _pid, _info} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, :running} -> :ok
      {:error, :restarting} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp child_id(%{id: id}), do: id
  defp child_id({module, _opts}) when is_atom(module), do: module
  defp child_id(module) when is_atom(module), do: module

  defp repo_name(%SystemSchema.Repo{name: name}), do: name
  defp repo_name(%{name: name}), do: name
  defp repo_name(%{"name" => name}), do: name
  defp repo_name(repo), do: inspect(repo)

  defp new_run_id(issue_id) when is_binary(issue_id) do
    "#{issue_id}-oneshot-#{System.system_time(:microsecond)}-#{System.unique_integer([:positive])}"
  end

  defp new_run_id(_issue_id) do
    "oneshot-#{System.system_time(:microsecond)}-#{System.unique_integer([:positive])}"
  end

  defp ignore_missing_run({:error, :run_not_found}), do: :ok
  defp ignore_missing_run(other), do: other

  defp log_run_store_error(:ok, _action), do: :ok

  defp log_run_store_error({:error, reason}, action) do
    Logger.warning("Failed to #{action}: #{inspect(reason)}")
    :ok
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
