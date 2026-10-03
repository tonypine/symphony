defmodule SymphonyElixir.TestSupport do
  alias SymphonyElixir.Config.Cache

  @workflow_prompt "You are an agent for this repository."
  @supervised_child_wait_ms 5_000
  @supervised_child_retry_ms 10

  defmacro __using__(_opts) do
    quote do
      use ExUnit.Case
      import ExUnit.CaptureLog

      alias SymphonyElixir.AgentRunner
      alias SymphonyElixir.CLI
      alias SymphonyElixir.Codex.AppServer
      alias SymphonyElixir.Config
      alias SymphonyElixir.Config.Cache
      alias SymphonyElixir.HttpServer
      alias SymphonyElixir.Linear.Client
      alias SymphonyElixir.Linear.Issue
      alias SymphonyElixir.Orchestrator
      alias SymphonyElixir.PromptBuilder
      alias SymphonyElixir.RunStore
      alias SymphonyElixir.StatusDashboard
      alias SymphonyElixir.Tracker
      alias SymphonyElixir.Workflow
      alias SymphonyElixir.WorkflowStore
      alias SymphonyElixir.Workspace

      import SymphonyElixir.TestSupport,
        only: [
          write_workflow_file!: 1,
          write_workflow_file!: 2,
          restore_env: 2,
          ensure_symphony_started!: 0,
          stop_default_orchestrator: 0,
          stop_default_http_server: 0,
          stop_process: 1,
          stop_verification_port_pool: 0,
          clear_run_store!: 0,
          unix_socket_bind_probe: 0,
          unix_socket_bind_probe: 1,
          unix_socket_bind_supported?: 0,
          unix_socket_bind_supported?: 1
        ]

      setup do
        workflow_root =
          Path.join(
            System.tmp_dir!(),
            "symphony-elixir-workflow-#{System.pid()}-#{System.unique_integer([:positive])}"
          )

        File.mkdir_p!(workflow_root)
        repo_root = Path.join(workflow_root, "repo")
        File.mkdir_p!(repo_root)
        workflow_file = Path.join(repo_root, "WORKFLOW.md")
        Workflow.set_symphony_file_path(Path.join(workflow_root, "symphony.yml"))
        Workflow.set_workflow_file_path(workflow_file)
        Application.put_env(:symphony_elixir, :config_cache_watch, false)
        Cache.clear()
        write_workflow_file!(workflow_file, tracker_api_token: nil)
        Workflow.set_workflow_file_path(workflow_file)
        ensure_symphony_started!()
        SymphonyElixir.TestSupport.ensure_pubsub_started!()
        if Process.whereis(SymphonyElixir.WorkflowStore), do: SymphonyElixir.WorkflowStore.force_reload()
        stop_default_orchestrator()
        :ok = SymphonyElixir.TestSupport.clear_run_store!()
        stop_verification_port_pool()
        stop_default_http_server()

        on_exit(fn ->
          stop_verification_port_pool()
          stop_default_orchestrator()
          stop_default_http_server()
          Application.delete_env(:symphony_elixir, :primary_repo_name)
          Application.delete_env(:symphony_elixir, :symphony_file_path)
          Application.delete_env(:symphony_elixir, :workflow_file_path)
          Application.delete_env(:symphony_elixir, :server_host_override)
          Application.delete_env(:symphony_elixir, :server_port_override)
          Application.delete_env(:symphony_elixir, :memory_tracker_issues)
          Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
          Application.delete_env(:symphony_elixir, :memory_tracker_update_issue_state_result)
          Application.delete_env(:symphony_elixir, :memory_tracker_fetch_candidate_sleep_ms)
          Application.delete_env(:symphony_elixir, :memory_tracker_fetch_states_sleep_ms)
          Application.delete_env(:symphony_elixir, :memory_tracker_create_comment_sleep_ms)
          Application.delete_env(:symphony_elixir, :config_cache_file_reader)
          Application.delete_env(:symphony_elixir, :config_cache_watch)
          Cache.clear()
          File.rm_rf(workflow_root)
        end)

        :ok
      end
    end
  end

  def write_workflow_file!(path, overrides \\ []) do
    overrides = Keyword.put_new(overrides, :workspace_root, Path.join(Path.dirname(path), "workspaces"))
    {system_config, repo_config, prompt} = split_workflow_content(path, overrides)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, repo_workflow_content(repo_config, prompt))
    File.write!(SymphonyElixir.Workflow.symphony_file_path(), symphony_content(system_config, path))
    Cache.clear()

    if Process.whereis(SymphonyElixir.WorkflowStore) do
      try do
        SymphonyElixir.WorkflowStore.force_reload()
      catch
        :exit, _reason -> :ok
      end
    end

    :ok
  end

  defp split_workflow_content(path, overrides) do
    {:ok, {config, prompt}} = SymphonyElixir.Workflow.parse_document(workflow_content(overrides))

    repo_config = Map.take(config, ["hooks", "prompts", "verification"])
    repos = Map.get(config, "repositories")
    tracker_team = get_in(config, ["issues", "linear", "scope", "team"])
    default_team = if is_binary(tracker_team) and String.trim(tracker_team) != "", do: tracker_team, else: "Test"

    default_repos = [
      %{
        "key" => "default",
        "workflow" => path,
        "route" => %{"team" => default_team}
      }
    ]

    system_config =
      config
      |> Map.drop(["hooks", "prompts", "verification"])
      |> Map.put("repositories", repos || default_repos)

    {system_config, repo_config, prompt}
  end

  defp symphony_content(config, _workflow_path) do
    config
    |> Enum.map_join("\n", fn {key, value} -> "#{key}: #{yaml_value(value)}" end)
    |> Kernel.<>("\n")
  end

  defp repo_workflow_content(config, prompt) when map_size(config) == 0 do
    prompt <> "\n"
  end

  defp repo_workflow_content(config, prompt) do
    [
      "---",
      Enum.map_join(config, "\n", fn {key, value} -> "#{key}: #{yaml_value(value)}" end),
      "---",
      prompt
    ]
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  def restore_env(key, nil), do: System.delete_env(key)
  def restore_env(key, value), do: System.put_env(key, value)

  def unix_socket_bind_supported?(root \\ System.tmp_dir!()) do
    unix_socket_bind_probe(root) == :ok
  end

  def unix_socket_bind_probe(root \\ System.tmp_dir!()) when is_binary(root) do
    dir = Path.join(root, "symphony-unix-socket-probe-#{System.unique_integer([:positive])}")
    path = Path.join(dir, "sock")

    with :ok <- File.mkdir_p(dir),
         {:ok, socket} <- :socket.open(:local, :stream) do
      try do
        with :ok <- :socket.bind(socket, %{family: :local, path: path}),
             :ok <- :socket.listen(socket) do
          :ok
        else
          {:error, reason} -> {:error, reason}
          other -> {:error, other}
        end
      after
        :socket.close(socket)
        File.rm_rf(dir)
      end
    else
      {:error, reason} ->
        File.rm_rf(dir)
        {:error, reason}
    end
  end

  def ensure_symphony_started! do
    ensure_application_started()
    ensure_named_supervised_child_started!(SymphonyElixir.TaskSupervisor, SymphonyElixir.TaskSupervisor)
  end

  def ensure_pubsub_started! do
    ensure_application_started()
    ensure_named_supervised_child_started!(Phoenix.PubSub.Supervisor, SymphonyElixir.PubSub)
  end

  def ensure_config_cache_started! do
    ensure_application_started()
    ensure_named_supervised_child_started!(Cache, Cache)
  end

  def clear_run_store! do
    case SymphonyElixir.RunStore.clear() do
      :ok ->
        :ok

      {:error, reason} ->
        recover_run_store!(reason)

        case SymphonyElixir.RunStore.clear() do
          :ok -> :ok
          {:error, retry_reason} -> raise "failed to clear RunStore after recovery: #{inspect(retry_reason)}"
        end
    end
  end

  def ensure_application_started do
    case named_process(SymphonyElixir.Supervisor) do
      pid when is_pid(pid) ->
        :ok

      _ ->
        do_ensure_application_started()
    end

    case wait_for_named_process(SymphonyElixir.Supervisor) do
      :ok -> :ok
      :timeout -> recover_missing_application_supervisor!()
    end
  end

  defp do_ensure_application_started do
    do_ensure_application_started(false)
  end

  defp do_ensure_application_started(recovered?) do
    case Application.ensure_all_started(:symphony_elixir) do
      {:ok, _started} -> :ok
      {:error, {:symphony_elixir, {:already_started, _pid}}} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} when not recovered? -> maybe_recover_application_start!(reason)
      {:error, reason} -> raise "failed to start symphony_elixir test application: #{inspect(reason)}"
    end
  end

  defp maybe_recover_application_start!(reason) do
    case orphan_run_store_pid(reason) do
      pid when is_pid(pid) ->
        stop_process(pid)
        stop_mnesia()
        do_ensure_application_started(true)

      nil ->
        raise "failed to start symphony_elixir test application: #{inspect(reason)}"
    end
  end

  defp orphan_run_store_pid({:symphony_elixir, {shutdown_reason, start_mfa}}) do
    case {shutdown_reason, start_mfa} do
      {
        {:shutdown, {:failed_to_start_child, SymphonyElixir.RunStore, {:already_started, pid}}},
        {SymphonyElixir.Application, :start, [:normal, []]}
      }
      when is_pid(pid) ->
        pid

      _other ->
        nil
    end
  end

  defp orphan_run_store_pid(_reason), do: nil

  defp recover_missing_application_supervisor! do
    _ = Application.stop(:symphony_elixir)
    do_ensure_application_started()
    wait_for_named_process!(SymphonyElixir.Supervisor)
  end

  defp ensure_named_supervised_child_started!(child_id, process_name) do
    case named_process(process_name) do
      pid when is_pid(pid) ->
        :ok

      _ ->
        ensure_named_supervised_child_started!(child_id, process_name, false)
    end
  end

  defp ensure_named_supervised_child_started!(child_id, process_name, recovered?) do
    :ok = ensure_application_started()
    restart_result = restart_supervised_child(child_id)

    case wait_for_named_process(process_name) do
      :ok ->
        :ok

      :timeout ->
        if not recovered? and recoverable_supervisor_restart_failure?(restart_result) do
          recover_missing_application_supervisor!()
          ensure_named_supervised_child_started!(child_id, process_name, true)
        else
          raise "failed to start #{inspect(process_name)} from child #{inspect(child_id)}: #{inspect(restart_result)}"
        end
    end
  end

  defp restart_supervised_child(child_id) do
    ensure_application_started()

    case named_process(SymphonyElixir.Supervisor) do
      supervisor when is_pid(supervisor) ->
        case Supervisor.restart_child(supervisor, child_id) do
          {:ok, _pid} -> :ok
          {:ok, _pid, _info} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, :running} -> :ok
          {:error, :restarting} -> :ok
          {:error, reason} -> {:error, reason}
        end

      _ ->
        do_ensure_application_started()
    end
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp recoverable_supervisor_shutdown?({:error, {:exit, {:shutdown, _reason}}}), do: true
  defp recoverable_supervisor_shutdown?({:error, {:exit, :shutdown}}), do: true
  defp recoverable_supervisor_shutdown?(_result), do: false

  defp recoverable_supervisor_restart_failure?(restart_result) do
    recoverable_supervisor_shutdown?(restart_result) or is_nil(named_process(SymphonyElixir.Supervisor))
  end

  defp recover_run_store!(reason) do
    run_store_dir = SymphonyElixir.RunStore.store_dir()
    stop_supervised_child(SymphonyElixir.RunStore)
    stop_mnesia()
    File.rm_rf(run_store_dir)
    File.mkdir_p!(run_store_dir)

    case restart_supervised_child(SymphonyElixir.RunStore) do
      :ok ->
        wait_for_named_process!(SymphonyElixir.RunStore)

      {:error, :not_found} ->
        recover_missing_application_supervisor!()
        wait_for_named_process!(SymphonyElixir.RunStore)

      {:error, restart_reason} ->
        raise "failed to recover RunStore after #{inspect(reason)}: #{inspect(restart_reason)}"
    end
  end

  defp stop_supervised_child(child_id) do
    pid = Process.whereis(child_id)

    case named_process(SymphonyElixir.Supervisor) do
      supervisor when is_pid(supervisor) ->
        case Supervisor.terminate_child(supervisor, child_id) do
          :ok -> :ok
          {:error, :not_found} -> :ok
          {:error, _reason} -> :ok
        end

      _ ->
        :ok
    end

    stop_process(pid)
  catch
    :exit, _reason -> stop_process(Process.whereis(child_id))
  end

  defp stop_mnesia do
    case :mnesia.stop() do
      :stopped -> :ok
      :ok -> :ok
      {:error, {:not_started, :mnesia}} -> :ok
    end
  catch
    :exit, _reason -> :ok
  end

  defp wait_for_named_process!(process_name) do
    case wait_for_named_process(process_name) do
      :ok -> :ok
      :timeout -> raise "timed out waiting for #{inspect(process_name)} to start"
    end
  end

  defp wait_for_named_process(process_name) do
    deadline_ms = System.monotonic_time(:millisecond) + @supervised_child_wait_ms
    wait_for_named_process(process_name, deadline_ms)
  end

  defp wait_for_named_process(process_name, deadline_ms) do
    case named_process(process_name) do
      pid when is_pid(pid) ->
        :ok

      _ ->
        if System.monotonic_time(:millisecond) >= deadline_ms do
          :timeout
        else
          Process.sleep(@supervised_child_retry_ms)
          wait_for_named_process(process_name, deadline_ms)
        end
    end
  end

  defp named_process(process_name) do
    case Process.whereis(process_name) do
      pid when is_pid(pid) ->
        case Process.info(pid, :status) do
          {:status, :exiting} -> nil
          nil -> nil
          _status -> pid
        end

      _ ->
        nil
    end
  end

  def stop_default_http_server do
    with supervisor when is_pid(supervisor) <- named_process(SymphonyElixir.Supervisor),
         {SymphonyElixir.HttpServer, pid, _type, _modules} when is_pid(pid) <- find_default_http_server(supervisor) do
      :ok = Supervisor.terminate_child(supervisor, SymphonyElixir.HttpServer)

      stop_process(pid)

      :ok
    else
      _ -> :ok
    end
  catch
    :exit, _reason -> :ok
  end

  def stop_default_orchestrator do
    with supervisor when is_pid(supervisor) <- named_process(SymphonyElixir.Supervisor),
         {SymphonyElixir.Orchestrator, pid, _type, _modules} when is_pid(pid) <-
           find_default_orchestrator(supervisor) do
      :ok = Supervisor.terminate_child(supervisor, SymphonyElixir.Orchestrator)

      stop_process(pid)

      :ok
    else
      _ -> :ok
    end
  catch
    :exit, _reason -> :ok
  end

  def stop_process(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      ref = Process.monitor(pid)
      Process.unlink(pid)
      Process.exit(pid, :shutdown)

      receive do
        {:DOWN, ^ref, :process, ^pid, _reason} ->
          :ok
      after
        1_000 ->
          Process.exit(pid, :kill)

          receive do
            {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
          after
            1_000 -> :ok
          end
      end
    else
      :ok
    end
  end

  def stop_process(_pid), do: :ok

  defp find_default_http_server(supervisor) do
    Enum.find(Supervisor.which_children(supervisor), fn
      {SymphonyElixir.HttpServer, _pid, _type, _modules} -> true
      _child -> false
    end)
  catch
    :exit, _reason -> nil
  end

  defp find_default_orchestrator(supervisor) do
    Enum.find(Supervisor.which_children(supervisor), fn
      {SymphonyElixir.Orchestrator, _pid, _type, _modules} -> true
      _child -> false
    end)
  catch
    :exit, _reason -> nil
  end

  def stop_verification_port_pool do
    case Process.whereis(SymphonyElixir.Verification.PortPool) do
      pid when is_pid(pid) -> GenServer.stop(pid)
      _ -> :ok
    end
  catch
    :exit, _reason -> :ok
  end

  defp workflow_content(overrides) do
    config =
      Keyword.merge(
        [
          tracker_kind: "linear",
          tracker_endpoint: "https://api.linear.app/graphql",
          tracker_api_token: "token",
          tracker_project_slug: "project",
          tracker_team: nil,
          tracker_labels: [],
          tracker_assignee: nil,
          tracker_active_states: ["Todo", "In Progress"],
          tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"],
          poll_interval_ms: 30_000,
          poller: nil,
          watchdog: nil,
          workspace_root: Path.join(System.tmp_dir!(), "symphony_workspaces"),
          workspace_strategy: "clone",
          workspace_repo: nil,
          workspace_fetch_before_dispatch: true,
          workspace_attachments: nil,
          workspace_sandbox: nil,
          workspace_lifecycle: nil,
          worker_ssh_hosts: [],
          worker_max_concurrent_agents_per_host: nil,
          github: nil,
          max_concurrent_agents: 10,
          epic_lanes: nil,
          max_turns: 20,
          max_retry_backoff_ms: 300_000,
          max_concurrent_agents_by_state: %{},
          max_consecutive_identical_tool_failures: 5,
          max_tokens_per_issue: nil,
          max_tokens_per_day: nil,
          agent_kind: "codex",
          agent_command: "codex app-server",
          agent_approval_policy: %{reject: %{sandbox_approval: true, rules: true, mcp_elicitations: true}},
          agent_include_project_guides: true,
          agent_project_guide_files: nil,
          agent_codex_stdio_soft_limit_bytes: nil,
          agent_thread_sandbox: "workspace-write",
          agent_turn_sandbox_policy: nil,
          agent_mcp: nil,
          agent_network_access: nil,
          agent_sandbox_runtime: nil,
          agent_turn_timeout_ms: 3_600_000,
          agent_read_timeout_ms: 30_000,
          agent_stall_timeout_ms: 300_000,
          agent_command_timeout_ms: 600_000,
          hook_after_create: nil,
          hook_before_run: nil,
          hook_after_run: nil,
          hook_before_remove: nil,
          hook_timeout_ms: 60_000,
          prompts: nil,
          observability_enabled: true,
          observability_refresh_ms: 1_000,
          observability_render_interval_ms: 16,
          observability_snapshot_publish_ms: 500,
          observability_transcript_buffer_size: 200,
          pr_review_mode: "tracker",
          pr_review_cooldown_minutes: nil,
          pr_review_stale_days: nil,
          pr_review_ignored_users: nil,
          pr_review_auto_reply: nil,
          pr_review_auto_request_review: nil,
          ci: nil,
          verification: nil,
          server_port: nil,
          server_host: nil,
          quality_gate: %{enabled: false},
          learnings: nil,
          review_agent: nil,
          auto_review: nil,
          dependencies: nil,
          notifications: nil,
          repos: nil,
          prompt: @workflow_prompt
        ],
        overrides
      )

    tracker_kind = Keyword.get(config, :tracker_kind)
    tracker_endpoint = Keyword.get(config, :tracker_endpoint)
    tracker_api_token = Keyword.get(config, :tracker_api_token)
    tracker_project_slug = Keyword.get(config, :tracker_project_slug)
    tracker_team = Keyword.get(config, :tracker_team)
    tracker_labels = Keyword.get(config, :tracker_labels)
    tracker_assignee = Keyword.get(config, :tracker_assignee)
    tracker_active_states = Keyword.get(config, :tracker_active_states)
    tracker_terminal_states = Keyword.get(config, :tracker_terminal_states)
    poll_interval_ms = Keyword.get(config, :poll_interval_ms)
    poller = Keyword.get(config, :poller)
    watchdog = Keyword.get(config, :watchdog)
    workspace_root = Keyword.get(config, :workspace_root)
    workspace_strategy = Keyword.get(config, :workspace_strategy)
    workspace_repo = Keyword.get(config, :workspace_repo)
    workspace_fetch_before_dispatch = Keyword.get(config, :workspace_fetch_before_dispatch)
    workspace_attachments = Keyword.get(config, :workspace_attachments)
    workspace_sandbox = Keyword.get(config, :workspace_sandbox)
    workspace_lifecycle = Keyword.get(config, :workspace_lifecycle)
    worker_ssh_hosts = Keyword.get(config, :worker_ssh_hosts)
    worker_max_concurrent_agents_per_host = Keyword.get(config, :worker_max_concurrent_agents_per_host)
    github = Keyword.get(config, :github)
    max_concurrent_agents = Keyword.get(config, :max_concurrent_agents)
    epic_lanes = Keyword.get(config, :epic_lanes)
    max_turns = Keyword.get(config, :max_turns)
    max_retry_backoff_ms = Keyword.get(config, :max_retry_backoff_ms)
    max_concurrent_agents_by_state = Keyword.get(config, :max_concurrent_agents_by_state)
    max_consecutive_identical_tool_failures = Keyword.get(config, :max_consecutive_identical_tool_failures)
    max_tokens_per_issue = Keyword.get(config, :max_tokens_per_issue)
    max_tokens_per_day = Keyword.get(config, :max_tokens_per_day)
    agent_kind = Keyword.get(config, :agent_kind)
    agent_command = Keyword.get(config, :agent_command)
    agent_approval_policy = Keyword.get(config, :agent_approval_policy)
    agent_include_project_guides = Keyword.get(config, :agent_include_project_guides)
    agent_project_guide_files = Keyword.get(config, :agent_project_guide_files)
    agent_codex_stdio_soft_limit_bytes = Keyword.get(config, :agent_codex_stdio_soft_limit_bytes)
    agent_thread_sandbox = Keyword.get(config, :agent_thread_sandbox)
    agent_turn_sandbox_policy = Keyword.get(config, :agent_turn_sandbox_policy)
    agent_network_access = Keyword.get(config, :agent_network_access)
    agent_sandbox_runtime = Keyword.get(config, :agent_sandbox_runtime)
    agent_turn_timeout_ms = Keyword.get(config, :agent_turn_timeout_ms)
    agent_read_timeout_ms = Keyword.get(config, :agent_read_timeout_ms)
    agent_stall_timeout_ms = Keyword.get(config, :agent_stall_timeout_ms)
    agent_command_timeout_ms = Keyword.get(config, :agent_command_timeout_ms)
    hook_after_create = Keyword.get(config, :hook_after_create)
    hook_before_run = Keyword.get(config, :hook_before_run)
    hook_after_run = Keyword.get(config, :hook_after_run)
    hook_before_remove = Keyword.get(config, :hook_before_remove)
    hook_timeout_ms = Keyword.get(config, :hook_timeout_ms)
    prompts = Keyword.get(config, :prompts)
    observability_enabled = Keyword.get(config, :observability_enabled)
    observability_refresh_ms = Keyword.get(config, :observability_refresh_ms)
    observability_render_interval_ms = Keyword.get(config, :observability_render_interval_ms)
    observability_snapshot_publish_ms = Keyword.get(config, :observability_snapshot_publish_ms)
    observability_transcript_buffer_size = Keyword.get(config, :observability_transcript_buffer_size)
    pr_review_mode = Keyword.get(config, :pr_review_mode)
    pr_review_cooldown_minutes = Keyword.get(config, :pr_review_cooldown_minutes)
    pr_review_stale_days = Keyword.get(config, :pr_review_stale_days)
    pr_review_ignored_users = Keyword.get(config, :pr_review_ignored_users)
    pr_review_auto_reply = Keyword.get(config, :pr_review_auto_reply)
    pr_review_auto_request_review = Keyword.get(config, :pr_review_auto_request_review)
    ci = Keyword.get(config, :ci)
    verification = Keyword.get(config, :verification)
    server_port = Keyword.get(config, :server_port)
    server_host = Keyword.get(config, :server_host)
    quality_gate = Keyword.get(config, :quality_gate)
    learnings = Keyword.get(config, :learnings)
    review_agent = Keyword.get(config, :review_agent)
    auto_review = Keyword.get(config, :auto_review)
    dependencies = Keyword.get(config, :dependencies)
    notifications = Keyword.get(config, :notifications)
    repos = Keyword.get(config, :repos)
    prompt = Keyword.get(config, :prompt)

    sections =
      [
        "---",
        issues_yaml(%{
          kind: tracker_kind,
          endpoint: tracker_endpoint,
          api_token: tracker_api_token,
          project_slug: tracker_project_slug,
          team: tracker_team,
          labels: tracker_labels,
          assignee: tracker_assignee,
          active_states: tracker_active_states,
          terminal_states: tracker_terminal_states,
          interval_ms: poll_interval_ms
        }),
        poller && "poller: #{yaml_value(poller)}",
        watchdog_yaml(watchdog),
        workspaces_yaml(
          workspace_root,
          workspace_strategy,
          workspace_repo,
          workspace_fetch_before_dispatch,
          workspace_attachments,
          workspace_lifecycle
        ),
        worker_yaml(worker_ssh_hosts, worker_max_concurrent_agents_per_host),
        github && "github: #{yaml_value(github)}",
        agent_yaml(%{
          kind: agent_kind,
          command: agent_command,
          model: Keyword.get(config, :agent_model),
          effort: Keyword.get(config, :agent_effort),
          provider: Keyword.get(config, :agent_provider),
          run_profiles: Keyword.get(config, :agent_run_profiles),
          max_concurrent_agents: max_concurrent_agents,
          epic_lanes: epic_lanes,
          max_concurrent_agents_by_state: max_concurrent_agents_by_state,
          max_turns: max_turns,
          max_retry_backoff_ms: max_retry_backoff_ms,
          max_consecutive_identical_tool_failures: max_consecutive_identical_tool_failures,
          max_tokens_per_issue: max_tokens_per_issue,
          max_tokens_per_day: max_tokens_per_day,
          turn_timeout_ms: agent_turn_timeout_ms,
          read_timeout_ms: agent_read_timeout_ms,
          stall_timeout_ms: agent_stall_timeout_ms,
          command_timeout_ms: agent_command_timeout_ms,
          include_project_guides: agent_include_project_guides,
          project_guide_files: agent_project_guide_files,
          codex_stdio_soft_limit_bytes: agent_codex_stdio_soft_limit_bytes,
          approval_policy: agent_approval_policy,
          thread_sandbox: agent_thread_sandbox,
          turn_sandbox_policy: agent_turn_sandbox_policy,
          workspace_sandbox: workspace_sandbox,
          network_access: agent_network_access,
          sandbox_runtime: agent_sandbox_runtime,
          mcp: Keyword.get(config, :agent_mcp)
        }),
        hooks_yaml(hook_after_create, hook_before_run, hook_after_run, hook_before_remove, hook_timeout_ms),
        prompts_yaml(prompts),
        dashboard_yaml(
          observability_enabled,
          observability_refresh_ms,
          observability_render_interval_ms,
          observability_snapshot_publish_ms,
          observability_transcript_buffer_size,
          server_port,
          server_host
        ),
        pull_requests_yaml(
          pr_review_mode,
          pr_review_cooldown_minutes,
          pr_review_stale_days,
          pr_review_ignored_users,
          pr_review_auto_reply,
          pr_review_auto_request_review,
          ci,
          learnings
        ),
        verification_yaml(verification),
        quality_gate_yaml(quality_gate),
        review_agent_yaml(review_agent),
        auto_review && "auto_review: #{yaml_value(auto_review)}",
        dependencies && "dependency_audit: #{yaml_value(dependencies)}",
        notifications_yaml(notifications),
        repos && "repositories: #{yaml_value(normalize_test_repositories(repos))}",
        "---",
        prompt
      ]
      |> Enum.reject(&(&1 in [nil, ""]))

    Enum.join(sections, "\n") <> "\n"
  end

  defp yaml_value(value) when is_binary(value) do
    escaped =
      value
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")
      |> String.replace("\n", "\\n")

    "\"" <> escaped <> "\""
  end

  defp yaml_value(value) when is_integer(value), do: to_string(value)
  defp yaml_value(true), do: "true"
  defp yaml_value(false), do: "false"
  defp yaml_value(nil), do: "null"

  defp yaml_value(values) when is_list(values) do
    "[" <> Enum.map_join(values, ", ", &yaml_value/1) <> "]"
  end

  defp yaml_value(values) when is_map(values) do
    "{" <>
      Enum.map_join(values, ", ", fn {key, value} ->
        "#{yaml_value(to_string(key))}: #{yaml_value(value)}"
      end) <> "}"
  end

  defp yaml_value(value), do: yaml_value(to_string(value))

  defp hooks_yaml(nil, nil, nil, nil, timeout_ms), do: "hooks:\n  timeout_ms: #{yaml_value(timeout_ms)}"

  defp hooks_yaml(hook_after_create, hook_before_run, hook_after_run, hook_before_remove, timeout_ms) do
    [
      "hooks:",
      "  timeout_ms: #{yaml_value(timeout_ms)}",
      hook_entry("after_create", hook_after_create),
      hook_entry("before_run", hook_before_run),
      hook_entry("after_run", hook_after_run),
      hook_entry("before_remove", hook_before_remove)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp issues_yaml(config) do
    [
      "issues:",
      "  provider: #{yaml_value(config.kind)}",
      "  poll_interval_ms: #{yaml_value(config.interval_ms)}",
      "  linear:",
      "    endpoint: #{yaml_value(config.endpoint)}",
      "    api_key: #{yaml_value(config.api_token)}",
      "    assignee: #{yaml_value(config.assignee)}",
      "    scope:",
      "      project_slug: #{yaml_value(config.project_slug)}",
      "      team: #{yaml_value(config.team)}",
      "      labels: #{yaml_value(config.labels)}",
      "  states:",
      "    active: #{yaml_value(config.active_states)}",
      "    terminal: #{yaml_value(config.terminal_states)}"
    ]
    |> Enum.join("\n")
  end

  defp workspaces_yaml(root, strategy, repo, fetch_before_dispatch, attachments, lifecycle) do
    [
      "workspaces:",
      "  root: #{yaml_value(root)}",
      "  strategy: #{yaml_value(strategy)}",
      "  repo: #{yaml_value(repo)}",
      "  fetch_before_dispatch: #{yaml_value(fetch_before_dispatch)}",
      attachments && "  attachments: #{yaml_value(attachments)}",
      lifecycle && "  cleanup: #{yaml_value(normalize_workspace_cleanup(lifecycle))}"
    ]
    |> Enum.reject(&(&1 in [nil, false]))
    |> Enum.join("\n")
  end

  defp normalize_workspace_cleanup(lifecycle) do
    lifecycle = map_from(lifecycle)

    %{}
    |> maybe_put(:enabled, lifecycle_value(lifecycle, :age_gc_enabled, :enabled))
    |> maybe_put(:max_age_days, Map.get(lifecycle, :max_age_days))
    |> maybe_put(:interval_ms, lifecycle_value(lifecycle, :gc_interval_ms, :interval_ms))
    |> maybe_put(:min_free_bytes, Map.get(lifecycle, :min_free_bytes))
    |> maybe_put(:orphan_action, Map.get(lifecycle, :orphan_action))
    |> maybe_put(:trash_dir, Map.get(lifecycle, :trash_dir))
  end

  defp lifecycle_value(lifecycle, primary_key, fallback_key) do
    cond do
      Map.has_key?(lifecycle, primary_key) -> Map.get(lifecycle, primary_key)
      Map.has_key?(lifecycle, fallback_key) -> Map.get(lifecycle, fallback_key)
      true -> nil
    end
  end

  defp worker_yaml(ssh_hosts, max_concurrent_agents_per_host)
       when ssh_hosts in [nil, []] and is_nil(max_concurrent_agents_per_host),
       do: nil

  defp worker_yaml(ssh_hosts, max_concurrent_agents_per_host) do
    [
      "workers:",
      ssh_hosts not in [nil, []] && "  ssh_hosts: #{yaml_value(ssh_hosts)}",
      !is_nil(max_concurrent_agents_per_host) &&
        "  max_concurrent_agents_per_host: #{yaml_value(max_concurrent_agents_per_host)}"
    ]
    |> Enum.reject(&(&1 in [nil, false]))
    |> Enum.join("\n")
  end

  defp agent_profile_yaml(config) do
    [:model, :effort, :provider, :run_profiles]
    |> Enum.reject(&is_nil(Map.get(config, &1)))
    |> Enum.map_join("\n", &"  #{&1}: #{yaml_value(Map.get(config, &1))}")
    |> case do
      "" -> nil
      lines -> lines
    end
  end

  defp agent_yaml(config) do
    filesystem = normalize_agent_filesystem(config.thread_sandbox, config.turn_sandbox_policy, config.workspace_sandbox)
    outer_sandbox = normalize_outer_sandbox(config.sandbox_runtime)

    [
      "agent:",
      "  runtime: #{yaml_value(config.kind)}",
      "  command: #{yaml_value(config.command)}",
      agent_profile_yaml(config),
      "  concurrency:",
      "    max_total: #{yaml_value(config.max_concurrent_agents)}",
      "    max_by_issue_state: #{yaml_value(config.max_concurrent_agents_by_state)}",
      !is_nil(config.epic_lanes) && "    epic_lanes: #{yaml_value(config.epic_lanes)}",
      "  limits:",
      "    max_turns: #{yaml_value(config.max_turns)}",
      "    retry_backoff_max_ms: #{yaml_value(config.max_retry_backoff_ms)}",
      "    max_consecutive_identical_tool_failures: #{yaml_value(config.max_consecutive_identical_tool_failures)}",
      "    tokens_per_issue: #{yaml_value(config.max_tokens_per_issue)}",
      "    tokens_per_day: #{yaml_value(config.max_tokens_per_day)}",
      "  timeouts:",
      "    turn_ms: #{yaml_value(config.turn_timeout_ms)}",
      "    read_ms: #{yaml_value(config.read_timeout_ms)}",
      "    stall_ms: #{yaml_value(config.stall_timeout_ms)}",
      "    command_ms: #{yaml_value(config.command_timeout_ms)}",
      "  prompts:",
      "    include_project_guides: #{yaml_value(config.include_project_guides)}",
      "    project_guide_files: #{yaml_value(config.project_guide_files)}",
      config.codex_stdio_soft_limit_bytes &&
        "    codex_stdio_soft_limit_bytes: #{yaml_value(config.codex_stdio_soft_limit_bytes)}",
      "  permissions:",
      "    approval_policy: #{yaml_value(config.approval_policy)}",
      "    filesystem: #{yaml_value(filesystem)}",
      config.network_access && "    network: #{yaml_value(config.network_access)}",
      outer_sandbox && "    outer_sandbox: #{yaml_value(outer_sandbox)}",
      config.mcp && "  mcp: #{yaml_value(config.mcp)}"
    ]
    |> Enum.reject(&(&1 in [nil, false]))
    |> Enum.join("\n")
  end

  defp normalize_agent_filesystem(thread_sandbox, turn_sandbox_policy, workspace_sandbox) do
    workspace_sandbox = if is_nil(workspace_sandbox), do: %{}, else: map_from(workspace_sandbox)

    %{}
    |> maybe_put(:sandbox, thread_sandbox)
    |> maybe_put(:turn_policy, turn_sandbox_policy)
    |> maybe_put(:allow_read_paths, Map.get(workspace_sandbox, :allow_read_paths))
    |> maybe_put(:allow_write_paths, Map.get(workspace_sandbox, :allow_write_paths))
  end

  defp normalize_outer_sandbox(nil), do: nil

  defp normalize_outer_sandbox(sandbox_runtime) do
    sandbox_runtime = map_from(sandbox_runtime)

    %{}
    |> maybe_put(:runtime, Map.get(sandbox_runtime, :kind) || Map.get(sandbox_runtime, :runtime))
    |> maybe_put(:command, Map.get(sandbox_runtime, :command))
    |> maybe_put(:enable_weaker_network_isolation, Map.get(sandbox_runtime, :enable_weaker_network_isolation))
  end

  defp watchdog_yaml(nil), do: nil

  defp watchdog_yaml(opts) when is_list(opts) or is_map(opts) do
    config = Map.new(opts)

    [
      "watchdog:",
      "  enabled: #{yaml_value(Map.get(config, :enabled))}",
      "  tick_interval_ms: #{yaml_value(Map.get(config, :tick_interval_ms))}",
      "  no_progress_threshold_ms: #{yaml_value(Map.get(config, :no_progress_threshold_ms))}"
    ]
    |> Enum.join("\n")
  end

  defp dashboard_yaml(enabled, refresh_ms, render_interval_ms, snapshot_publish_ms, transcript_buffer_size, port, host) do
    [
      "dashboard:",
      "  enabled: #{yaml_value(enabled)}",
      "  refresh_ms: #{yaml_value(refresh_ms)}",
      "  render_interval_ms: #{yaml_value(render_interval_ms)}",
      "  snapshot_publish_ms: #{yaml_value(snapshot_publish_ms)}",
      "  transcript_buffer_size: #{yaml_value(transcript_buffer_size)}",
      port && "  port: #{yaml_value(port)}",
      host && "  host: #{yaml_value(host)}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp pull_requests_yaml(mode, cooldown_minutes, stale_days, ignored_users, auto_reply, auto_request_review, ci, learnings) do
    ci = if is_nil(ci), do: %{}, else: map_from(ci)
    enabled = pull_requests_enabled_value(mode)

    [
      "pull_requests:",
      "  enabled: #{yaml_value(enabled)}",
      "  poll_interval_ms: #{yaml_value(Map.get(ci, :poll_interval_ms))}",
      "  review_comments:",
      "    rework_delay_minutes: #{yaml_value(cooldown_minutes)}",
      "    stale_after_days: #{yaml_value(stale_days)}",
      "    ignored_reviewers: #{yaml_value(ignored_users)}",
      "    reply_after_addressing: #{yaml_value(auto_reply)}",
      "    request_review_after_push: #{yaml_value(auto_request_review)}",
      checks_yaml(ci),
      learnings && "  learnings: #{yaml_value(learnings)}"
    ]
    |> Enum.reject(&(&1 in [nil, false]))
    |> Enum.join("\n")
  end

  defp pull_requests_enabled_value("polling"), do: true
  defp pull_requests_enabled_value("tracker"), do: false
  defp pull_requests_enabled_value(nil), do: nil
  defp pull_requests_enabled_value(value), do: value

  defp checks_yaml(ci) when map_size(ci) == 0, do: nil

  defp checks_yaml(ci) do
    [
      "  checks:",
      "    enabled: #{yaml_value(Map.get(ci, :enabled))}",
      "    log_excerpt_lines: #{yaml_value(Map.get(ci, :log_excerpt_lines))}",
      "    retry_failed_once: #{yaml_value(Map.get(ci, :flaky_retry))}",
      "    max_fix_attempts: #{yaml_value(Map.get(ci, :max_retries))}",
      "    escalate_to_state: #{yaml_value(Map.get(ci, :escalation_state))}"
    ]
    |> Enum.join("\n")
  end

  defp normalize_test_repositories(repos) do
    Enum.map(repos, &normalize_test_repository/1)
  end

  defp normalize_test_repository(repo) when is_list(repo) or is_map(repo) do
    repo = map_from(repo)
    route = normalize_test_repository_route(repo)
    workspace = Map.get(repo, :workspace) || Map.get(repo, "workspace")

    %{}
    |> maybe_put(:key, Map.get(repo, :key) || Map.get(repo, "key") || Map.get(repo, :name) || Map.get(repo, "name"))
    |> maybe_put(:workflow, normalize_test_repository_workflow(repo))
    |> maybe_put(:base_branch, Map.get(repo, :base_branch) || Map.get(repo, "base_branch"))
    |> maybe_put(:default, Map.get(repo, :default) || Map.get(repo, "default"))
    |> maybe_put(:route, route)
    |> maybe_put(:workspace, workspace)
    |> maybe_put(:agent, Map.get(repo, :agent) || Map.get(repo, "agent"))
  end

  defp normalize_test_repository_route(repo) do
    %{}
    |> maybe_put(:team, Map.get(repo, :team) || Map.get(repo, "team"))
    |> maybe_put(:projects, Map.get(repo, :projects) || Map.get(repo, "projects"))
    |> maybe_put(:labels, Map.get(repo, :labels) || Map.get(repo, "labels"))
    |> maybe_put(:assignee, Map.get(repo, :assignee) || Map.get(repo, "assignee"))
  end

  defp normalize_test_repository_workflow(repo) do
    workflow = Map.get(repo, :workflow) || Map.get(repo, "workflow")
    path = Map.get(repo, :path) || Map.get(repo, "path")

    cond do
      is_nil(workflow) -> nil
      is_nil(path) -> workflow
      Path.type(workflow) == :absolute -> workflow
      true -> Path.join(path, workflow)
    end
  end

  defp verification_yaml(nil), do: nil

  defp verification_yaml(opts) when is_list(opts) or is_map(opts) do
    config = map_from(opts)
    port_allocation = map_from(Map.get(config, :port_allocation) || %{})
    dev_server = map_from(Map.get(config, :dev_server) || %{})

    fields =
      [
        kv("enabled", Map.get(config, :enabled)),
        nested_yaml("port_allocation", [
          kv("range", Map.get(port_allocation, :range))
        ]),
        nested_yaml("dev_server", [
          kv("start_cmd", Map.get(dev_server, :start_cmd)),
          kv("health_check_url", Map.get(dev_server, :health_check_url)),
          kv("health_timeout_ms", Map.get(dev_server, :health_timeout_ms)),
          kv("stop_signal", Map.get(dev_server, :stop_signal)),
          kv("stop_timeout_ms", Map.get(dev_server, :stop_timeout_ms))
        ])
      ]
      |> Enum.reject(&is_nil/1)

    case fields do
      [] -> nil
      lines -> Enum.join(["verification:" | lines], "\n")
    end
  end

  defp nested_yaml(name, fields) do
    fields = Enum.reject(fields, &is_nil/1)

    case fields do
      [] -> nil
      lines -> Enum.join(["  #{name}:" | Enum.map(lines, &"  #{&1}")], "\n")
    end
  end

  defp quality_gate_yaml(nil), do: nil

  defp quality_gate_yaml(opts) when is_list(opts) or is_map(opts) do
    config = map_from(opts)

    fields =
      [
        kv("enabled", Map.get(config, :enabled)),
        kv("provider", Map.get(config, :provider)),
        kv("model", Map.get(config, :model)),
        kv("pass_threshold", Map.get(config, :pass_threshold)),
        kv("clarification_floor", Map.get(config, :clarification_floor)),
        kv("max_clarification_rounds", Map.get(config, :max_clarification_rounds)),
        kv("on_error", Map.get(config, :on_error))
      ]
      |> Enum.reject(&is_nil/1)

    case fields do
      [] -> nil
      lines -> Enum.join(["issue_gate:" | lines], "\n")
    end
  end

  defp review_agent_yaml(nil), do: nil

  defp review_agent_yaml(opts) when is_list(opts) or is_map(opts) do
    config = map_from(opts)

    fields =
      [
        kv("enabled", Map.get(config, :enabled)),
        kv("runtime", Map.get(config, :kind)),
        kv("command", Map.get(config, :command)),
        kv("model", Map.get(config, :model)),
        kv("effort", Map.get(config, :effort)),
        kv("max_iterations", Map.get(config, :max_iterations)),
        kv("run_on", Map.get(config, :run_on))
      ]
      |> Enum.reject(&is_nil/1)

    case fields do
      [] -> nil
      lines -> Enum.join(["pre_push_review:" | lines], "\n")
    end
  end

  defp notifications_yaml(nil), do: nil

  defp notifications_yaml(opts) when is_list(opts) or is_map(opts) do
    config = map_from(opts)

    fields =
      [
        kv("enabled", Map.get(config, :enabled)),
        kv("redact_titles", Map.get(config, :redact_titles)),
        notification_channels_yaml(Map.get(config, :channels))
      ]
      |> Enum.reject(&is_nil/1)

    case fields do
      [] -> nil
      lines -> Enum.join(["notifications:" | lines], "\n")
    end
  end

  defp notification_channels_yaml(nil), do: nil
  defp notification_channels_yaml([]), do: "  channels: []"

  defp notification_channels_yaml(channels) when is_list(channels) do
    channel_lines =
      channels
      |> Enum.map(&notification_channel_yaml/1)
      |> Enum.reject(&is_nil/1)

    if channel_lines == [] do
      nil
    else
      Enum.join(["  channels:" | channel_lines], "\n")
    end
  end

  defp notification_channels_yaml(_channels), do: nil

  defp notification_channel_yaml(channel) when is_list(channel) or is_map(channel) do
    channel = map_from(channel)

    [
      "    - kind: #{yaml_value(Map.get(channel, :kind))}",
      notification_channel_entry("webhook_url", Map.get(channel, :webhook_url)),
      notification_channel_entry("url", Map.get(channel, :url)),
      notification_channel_entry("events", Map.get(channel, :events)),
      notification_headers_yaml(Map.get(channel, :headers))
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp notification_channel_yaml(_channel), do: nil

  defp notification_channel_entry(_name, nil), do: nil
  defp notification_channel_entry(name, value), do: "      #{name}: #{yaml_value(value)}"

  defp notification_headers_yaml(nil), do: nil
  defp notification_headers_yaml(headers) when headers == %{}, do: nil

  defp notification_headers_yaml(headers) when is_map(headers) do
    entries =
      Enum.map_join(headers, "\n", fn {key, value} -> "        #{key}: #{yaml_value(value)}" end)

    "      headers:\n" <> entries
  end

  defp notification_headers_yaml(_headers), do: nil

  defp prompts_yaml(nil), do: nil
  defp prompts_yaml(prompts), do: "prompts: #{yaml_value(prompts)}"

  defp map_from(opts) when is_list(opts), do: Enum.into(opts, %{})
  defp map_from(opts) when is_map(opts), do: opts

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, %{} = value) when map_size(value) == 0, do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp kv(_name, nil), do: nil
  defp kv(name, value), do: "  #{name}: #{yaml_value(value)}"

  defp hook_entry(_name, nil), do: nil

  defp hook_entry(name, command) when is_binary(command) do
    indented =
      command
      |> String.split("\n")
      |> Enum.map_join("\n", &("    " <> &1))

    "  #{name}: |\n#{indented}"
  end
end
